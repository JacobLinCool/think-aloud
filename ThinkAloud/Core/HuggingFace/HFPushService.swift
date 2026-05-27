import Foundation

struct HFPushOptions: Sendable {
    let repoName: String                 // e.g. "thinkaloud-personal"
    let organization: String?            // nil → personal namespace
    let isPrivate: Bool
    let includeAudio: Bool

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

        // 1. Pull records + stage files on disk.
        await progress(HFPushProgress(stage: .prepare, completed: 0, total: 0, currentLabel: ""))
        let records = try await datasetStore.all()

        let staging = try makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        let metadataURL = staging.appendingPathComponent("metadata.jsonl")
        let readmeURL = staging.appendingPathComponent("README.md")
        try writeMetadataJSONL(records: records, to: metadataURL)
        try writeReadme(records: records, to: readmeURL)

        var stagedFiles: [(repoPath: String, localURL: URL)] = [
            ("metadata.jsonl", metadataURL),
            ("README.md", readmeURL)
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

    private func writeMetadataJSONL(records: [DatasetRecord], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var lines: [String] = []
        for record in records {
            let data = try encoder.encode(record)
            guard let line = String(data: data, encoding: .utf8) else { continue }
            lines.append(line)
        }
        let text = lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func writeReadme(records: [DatasetRecord], to url: URL) throws {
        let langCounts = Dictionary(grouping: records, by: { $0.language ?? "unknown" }).mapValues(\.count)
        let modelCounts = Dictionary(grouping: records, by: { $0.asrModel }).mapValues(\.count)
        var text = """
        ---
        license: other
        task_categories:
        - automatic-speech-recognition
        ---

        # ThinkAloud personal dataset

        Generated by [ThinkAloud](https://github.com/JacobLinCool/think-aloud) on \(ISO8601DateFormatter().string(from: Date())).

        ## Stats

        - Total records: \(records.count)

        """
        if !langCounts.isEmpty {
            text += "\n### Languages\n\n"
            for (lang, n) in langCounts.sorted(by: { $0.value > $1.value }) {
                text += "- \(lang): \(n)\n"
            }
        }
        if !modelCounts.isEmpty {
            text += "\n### Models\n\n"
            for (model, n) in modelCounts.sorted(by: { $0.value > $1.value }) {
                text += "- \(model): \(n)\n"
            }
        }
        text += """

        ## Layout

        - `metadata.jsonl` — one JSON record per line; mirrors ThinkAloud's local SQLite schema.
        - `audio/<yyyy-mm-dd>/<id>.wav` — 16 kHz mono PCM recordings; path matches each record's `audio_path` field.
        """
        try Data(text.utf8).write(to: url, options: .atomic)
    }
}
