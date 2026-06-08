import Foundation

struct HFPushOptions: Sendable {
    let repoName: String                 // e.g. "thinkaloud-personal"
    let organization: String?            // nil → personal namespace
    let isPrivate: Bool
    let includeAudio: Bool
    /// Opt-in (default OFF). When false, `source_app_bundle_id`/`source_app_name` are stripped from
    /// every uploaded row — which app you dictate into is private behavior the dataset doesn't need.
    let includeSourceApp: Bool

    /// Full repo id as the API expects it ("<owner>/<name>").
    func repoID(defaultOwner: String) -> String {
        let owner = organization ?? defaultOwner
        return "\(owner)/\(repoName)"
    }
}

/// One staged file ready to be sent in a commit. We resolve regular vs LFS routing per file
/// based on preupload's response, then either base64-inline (regular) or LFS-upload + lfsFile
/// reference (LFS).
struct HFPushProgress: Sendable {
    enum Stage: String, Sendable {
        case prepare
        case createRepo
        case preupload
        case lfsUpload
        case commit
        case done
    }
    let stage: Stage
    let completed: Int
    let total: Int
    let currentLabel: String
}

struct HFPushResult: Sendable {
    let repoID: String
    let commitURL: String?
    let pageURL: String   // human-friendly dataset page
    let uploadedFileCount: Int
}

actor HFPushService {
    private let client: HFHubClient
    private let datasetStore: DatasetStore
    private let audioFileStore: AudioFileStore
    private let defaultOwner: String   // from whoami

    init(client: HFHubClient, datasetStore: DatasetStore, audioFileStore: AudioFileStore, defaultOwner: String) {
        self.client = client
        self.datasetStore = datasetStore
        self.audioFileStore = audioFileStore
        self.defaultOwner = defaultOwner
    }

    func push(options: HFPushOptions, progress: @Sendable (HFPushProgress) async -> Void = { _ in }) async throws -> HFPushResult {
        let repoID = options.repoID(defaultOwner: defaultOwner)

        // 1. Pull records + stage files on disk. Defense-in-depth: only `savedToDataset` rows are
        // published (today every row is, but this guards a future "review later" state).
        await progress(HFPushProgress(stage: .prepare, completed: 0, total: 0, currentLabel: ""))
        let records = try await datasetStore.all().filter(\.savedToDataset)
        let stats = DatasetStatistics.compute(from: records)

        let staging = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        let metadataURL = staging.appendingPathComponent("metadata.jsonl")
        let readmeURL = staging.appendingPathComponent("README.md")
        let statsURL = staging.appendingPathComponent("statistics.json")
        try writeMetadataJSONL(records: records, includeAudio: options.includeAudio, includeSourceApp: options.includeSourceApp, to: metadataURL)
        try writeReadme(stats: stats, options: options, to: readmeURL)
        try writeStatisticsJSON(stats: stats.publicProjection(), to: statsURL)

        var stagedFiles: [(repoPath: String, localURL: URL)] = [
            ("metadata.jsonl", metadataURL),
            ("README.md", readmeURL),
            ("statistics.json", statsURL)
        ]
        if options.includeAudio {
            for record in records {
                let src = await audioFileStore.absoluteURL(for: record.audioPath)
                guard FileManager.default.fileExists(atPath: src.path) else { continue }
                // Upload at the exact relative path the DB stores in audio_path, so
                // metadata.jsonl (which encodes record.audioPath as-is) resolves correctly
                // against the repo layout. AudioFileStore guarantees the path starts with
                // "audio/" so it sits cleanly inside the dataset repo.
                stagedFiles.append((record.audioPath, src))
            }
        }

        // 2. Create repo (idempotent).
        await progress(HFPushProgress(stage: .createRepo, completed: 0, total: 1, currentLabel: repoID))
        try await client.createDatasetRepo(name: options.repoName, organization: options.organization, isPrivate: options.isPrivate)

        // 3. Preupload to determine regular vs LFS routing.
        await progress(HFPushProgress(stage: .preupload, completed: 0, total: stagedFiles.count, currentLabel: ""))
        let preuploadEntries: [HFHubClient.PreuploadFileEntry] = try stagedFiles.map { staged in
            let attrs = try FileManager.default.attributesOfItem(atPath: staged.localURL.path)
            let size = (attrs[.size] as? Int) ?? 0
            let sample = try HFHubClient.sampleBase64(fileURL: staged.localURL, bytes: 512)
            return .init(path: staged.repoPath, sampleBase64: sample, size: size)
        }
        let routing = try await client.preupload(repoID: repoID, files: preuploadEntries)
        let routingByPath = Dictionary(uniqueKeysWithValues: routing.map { ($0.path, $0) })

        // 4. LFS upload pass for files routed to LFS.
        var commitOps: [HFHubClient.CommitOp] = [
            .header(summary: "Push from ThinkAloud", description: "Uploaded \(records.count) records on \(ISO8601DateFormatter().string(from: Date())).")
        ]

        let lfsFiles = stagedFiles.filter { (routingByPath[$0.repoPath]?.uploadMode ?? "regular") == "lfs" }
        var lfsObjects: [(repoPath: String, localURL: URL, oid: String, size: Int)] = []
        for (i, staged) in lfsFiles.enumerated() {
            await progress(HFPushProgress(stage: .lfsUpload, completed: i, total: lfsFiles.count, currentLabel: staged.repoPath))
            try Task.checkCancellation()
            let (oid, size) = try HFHubClient.sha256Hex(fileURL: staged.localURL)
            lfsObjects.append((staged.repoPath, staged.localURL, oid, size))
        }

        if !lfsObjects.isEmpty {
            let batch = try await client.lfsBatch(
                repoID: repoID,
                objects: lfsObjects.map { .init(oid: $0.oid, size: $0.size) }
            )
            let instructionsByOid = Dictionary(uniqueKeysWithValues: batch.map { ($0.oid, $0) })
            for (i, obj) in lfsObjects.enumerated() {
                try Task.checkCancellation()
                await progress(HFPushProgress(stage: .lfsUpload, completed: i, total: lfsObjects.count, currentLabel: obj.repoPath))
                if let inst = instructionsByOid[obj.oid] {
                    try await client.lfsUpload(instruction: inst, fileURL: obj.localURL)
                    try await client.lfsVerify(instruction: inst)
                }
                // If no instruction returned, object already exists on the server — skip upload.
                commitOps.append(.lfsFile(path: obj.repoPath, oid: obj.oid, size: obj.size))
            }
        }

        // 5. Inline-base64 the small files into the commit.
        let regularFiles = stagedFiles.filter { (routingByPath[$0.repoPath]?.uploadMode ?? "regular") != "lfs" }
        for staged in regularFiles {
            let data = try Data(contentsOf: staged.localURL)
            commitOps.append(.fileBase64(path: staged.repoPath, content: data))
        }

        // 6. Commit.
        await progress(HFPushProgress(stage: .commit, completed: 0, total: 1, currentLabel: repoID))
        let result = try await client.commit(repoID: repoID, operations: commitOps)

        let pageURL = "https://huggingface.co/datasets/\(repoID)"
        await progress(HFPushProgress(stage: .done, completed: stagedFiles.count, total: stagedFiles.count, currentLabel: repoID))
        return HFPushResult(repoID: repoID, commitURL: result.commitURL, pageURL: pageURL, uploadedFileCount: stagedFiles.count)
    }

    // MARK: - Staging file generation

    private func makeStagingDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ThinkAloudPush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeMetadataJSONL(records: [DatasetRecord], includeAudio: Bool, includeSourceApp: Bool, to url: URL) throws {
        var lines: [String] = []
        for record in records {
            let row = Self.metadataRow(for: record, includeAudio: includeAudio, includeSourceApp: includeSourceApp)
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
            guard let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
        }
        let text = lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Explicit upload allowlist. We never serialize the whole `DatasetRecord`, so internal / free-form
    /// columns (`asr_config_json`, `metadata_json`, `saved_to_dataset`) and the opt-out source-app
    /// fields can't leak into a (possibly public) repo, and a future schema column won't auto-publish.
    /// `auto_edited_transcript` and the manual-edit fields are emitted on EVERY row (explicit `null`
    /// when absent) so the JSONL column type is consistent for HF schema inference.
    /// Static + non-private so the privacy allowlist can be unit-tested directly.
    static func metadataRow(for r: DatasetRecord, includeAudio: Bool, includeSourceApp: Bool) -> [String: Any] {
        let editedN = TextMetrics.normalize(r.editedTranscript, mode: .light)
        var row: [String: Any] = [
            "id": r.id,
            "created_at": r.createdAt,
            "duration_ms": r.durationMs.map { $0 as Any } ?? NSNull(),
            "sample_rate": r.sampleRate.map { $0 as Any } ?? NSNull(),
            "channels": r.channels.map { $0 as Any } ?? NSNull(),
            "language": r.language.map { $0 as Any } ?? NSNull(),
            "asr_provider": r.asrProvider,
            "asr_model": r.asrModel,
            "asr_runtime": r.asrRuntime,
            "raw_transcript": r.rawTranscript,
            "auto_edited_transcript": r.autoEditedTranscript.map { $0 as Any } ?? NSNull(),
            "llm_edited_transcript": r.llmEditedTranscript.map { $0 as Any } ?? NSNull(),
            "edited_transcript": r.editedTranscript,
            "inserted": r.inserted,
            "audio_path": r.audioPath,
            // Derived — scalar units, matching statistics.json.
            "raw_char_count": r.rawTranscript.unicodeScalars.count,
            "edited_char_count": r.editedTranscript.unicodeScalars.count,
            "token_count": TextMetrics.wordTokens(r.editedTranscript).count,
        ]
        // Manual-edit metrics measure the HUMAN delta on top of the last AUTOMATIC stage: the LLM
        // rewrite when AI Refine ran, else the deterministic auto-post-edit. Never raw-fallback (the
        // S↔T conversion / LLM rewrite would otherwise read as a huge "human edit"). Null when neither
        // intermediate was captured.
        if let base = r.llmEditedTranscript ?? r.autoEditedTranscript {
            let baseN = TextMetrics.normalize(base, mode: .light)
            let dist = TextMetrics.editDistanceScalars(baseN, editedN)
            let refLen = baseN.unicodeScalars.count
            row["manual_edit_distance"] = dist
            row["manual_edit_rate"] = refLen == 0 ? (editedN.unicodeScalars.isEmpty ? 0.0 : 1.0) : min(1.0, Double(dist) / Double(refLen))
        } else {
            row["manual_edit_distance"] = NSNull()
            row["manual_edit_rate"] = NSNull()
        }
        if includeAudio {
            // HF AudioFolder loader requires `file_name` pointing at the repo-relative audio path.
            row["file_name"] = r.audioPath
        }
        if includeSourceApp {
            row["source_app_bundle_id"] = r.sourceAppBundleID.map { $0 as Any } ?? NSNull()
            row["source_app_name"] = r.sourceAppName.map { $0 as Any } ?? NSNull()
        }
        return row
    }

    private func writeStatisticsJSON(stats: DatasetStatistics, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(stats)
        try data.write(to: url, options: .atomic)
    }

    private func writeReadme(stats: DatasetStatistics, options: HFPushOptions, to url: URL) throws {
        // Render from the privacy-safe projection: no source-app breakdown, no dated calendar.
        let s = stats.publicProjection()
        func hours(_ ms: Int) -> String { String(format: "%.1f", Double(ms) / 3_600_000) }
        func pct(_ frac: Double) -> String { "\(Int((frac * 100).rounded()))%" }
        func secs(_ ms: Int) -> String { String(format: "%.1fs", Double(ms) / 1000) }

        let langLine = s.byLanguage.map(\.key).filter { $0 != "unknown" }
        var front = """
        ---
        license: other
        task_categories:
        - automatic-speech-recognition
        """
        if !langLine.isEmpty {
            front += "\nlanguage:\n" + langLine.map { "- \($0)" }.joined(separator: "\n")
        }
        front += "\n---\n"

        var text = front + """

        # ThinkAloud personal dataset

        Generated by [ThinkAloud](https://github.com/JacobLinCool/think-aloud) on \(ISO8601DateFormatter().string(from: Date())).

        Speech paired with transcripts, captured while dictating on macOS. Each row keeps the raw ASR
        output, the automatically formatted text, and the final text the author kept — useful both for
        ASR fine-tuning and for studying post-ASR correction.

        ## Summary

        | Metric | Value |
        | --- | --- |
        | Recordings | \(s.recordCount) |
        | Total speech | \(hours(s.audio.totalDurationMs)) hours |
        | Date range | \(s.firstRecordDay ?? "—") – \(s.lastRecordDay ?? "—") (\(s.activeDayCount) active days) |
        | Characters (final) | \(s.text.totalEditedChars) |
        | Tokens (final) | \(s.text.totalTokens) |
        | Chinese characters | \(s.text.totalEditedChars > 0 ? pct(Double(s.text.totalCJKChars) / Double(s.text.totalEditedChars)) : "—") |

        ## Recording length

        | Stat | Value |
        | --- | --- |
        | Mean | \(secs(s.audio.meanMs)) |
        | Median | \(secs(s.audio.medianMs)) |

        """
        if s.audio.recordsWithDuration >= 10 {
            text += "| 90th percentile | \(secs(s.audio.p90Ms)) |\n"
        }
        text += "| Shortest / longest | \(secs(s.audio.minMs)) / \(secs(s.audio.maxMs)) |\n"
        text += "\nDistribution:\n\n| Length | Recordings |\n| --- | --- |\n"
        for b in s.audio.histogram where b.count > 0 {
            text += "| \(b.label) | \(b.count) |\n"
        }

        // Transcript quality — eligible (v0.4.0+) records only.
        if s.editing.eligibleCount > 0 {
            text += """

            ## Transcript quality

            Over the \(s.editing.eligibleCount) recordings that captured the auto-formatted intermediate
            (ThinkAloud v0.4.0+). `raw` and `auto` distances are baselined on different references, so they
            are reported as independent rates — not a sum.

            | Metric | Value |
            | --- | --- |
            | Came out clean (no human edit) | \(pct(s.editing.cleanRate)) |
            | Manual edit rate (micro, length-weighted) | \(pct(s.editing.microEditRate)) |
            | Manual edit rate (macro, per-recording mean) | \(pct(s.editing.meanEditRate)) |

            """
        }

        if !s.byLanguage.isEmpty {
            text += "\n## Languages\n\n| Language | Recordings |\n| --- | --- |\n"
            for b in s.byLanguage { text += "| \(b.displayName) | \(b.count) |\n" }
        }
        if !s.byModel.isEmpty {
            text += "\n## Models\n\n| Model | Recordings |\n| --- | --- |\n"
            for b in s.byModel { text += "| \(b.displayName) | \(b.count) |\n" }
        }

        let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        text += "\n## Activity\n\nAggregate cadence only — no per-recording timestamps are published.\n\n"
        text += "Recordings by weekday: " + (0..<7).map { "\(weekdayNames[$0]) \(s.activityByWeekday[$0])" }.joined(separator: " · ") + "\n"

        text += """

        ## Files

        - `metadata.jsonl` — one JSON object per line (schema below).
        - `statistics.json` — the aggregate statistics above, machine-readable.
        """
        if options.includeAudio {
            text += "\n- `audio/<yyyy-mm-dd>/<id>.wav` — 16 kHz mono PCM recordings; path matches each row's `file_name` (and `audio_path`)."
        }

        text += """


        ## Schema (`metadata.jsonl`)

        Pipeline: `raw_transcript` (model output) → `auto_edited_transcript` (automatic formatting:
        Chinese conversion, CJK–Latin spacing, custom dictionary) → `llm_edited_transcript` (optional
        on-device LLM "AI Refine" rewrite) → `edited_transcript` (final, after any human correction).

        | Field | Meaning |
        | --- | --- |
        | `id`, `created_at` | record id and ISO8601 timestamp |
        | `duration_ms`, `sample_rate`, `channels` | audio properties |
        | `language`, `asr_provider`, `asr_model`, `asr_runtime` | recognition engine |
        | `raw_transcript` / `auto_edited_transcript` / `llm_edited_transcript` / `edited_transcript` | pipeline stages (`auto_edited` is `null` for pre-v0.4.0 rows; `llm_edited` is `null` when AI Refine didn't run) |
        | `inserted` | whether the text was inserted into the focused app |
        | `raw_char_count`, `edited_char_count`, `token_count` | derived counts (unicode scalars; tokens per the WER convention) |
        | `manual_edit_distance`, `manual_edit_rate` | human edits on top of the last automatic stage (`llm_edited` if AI Refine ran, else `auto_edited`); `null` when neither was captured |
        | `audio_path`\(options.includeAudio ? ", `file_name`" : "") | audio location |
        \(options.includeSourceApp ? "| `source_app_bundle_id`, `source_app_name` | the app dictated into |\n" : "")

        \(options.includeSourceApp ? "Source-app names **are** included in this export." : "Source-app names are **not** included.")
        """
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
