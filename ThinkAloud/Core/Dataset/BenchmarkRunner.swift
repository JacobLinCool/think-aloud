import Foundation
import MLX
import MLXAudioCore

struct BenchmarkResult: Sendable, Identifiable, Codable, Equatable {
    let id: String                  // record id
    let recordCreatedAt: String
    let groundTruth: String         // record.editedTranscript at run time (treated as ground truth)
    let predictedRaw: String        // model output before post-process
    let predictedEdited: String     // after TranscriptPostProcessor (final pipeline output)

    // Strict scoring — whitespace-only normalization. Preserves case + punctuation + full-width.
    let editDistance: Int
    let referenceLength: Int
    let cer: Double
    let exactMatch: Bool

    // Lenient scoring — aggressive normalization (lowercase, full→half width, strip punctuation).
    // Matches the convention Whisper-style ASR benchmarks report. Optional for forward-compat
    // with any legacy in-memory report objects that predate this field.
    let editDistanceNormalized: Int?
    let referenceLengthNormalized: Int?
    let cerNormalized: Double?
    let exactMatchNormalized: Bool?

    let durationMs: Int
    let error: String?

    var passed: Bool { error == nil }

    /// Pick the right metric tuple based on the user's display toggle. Falls back to the strict
    /// fields when an older report doesn't carry normalized values.
    func cer(useNormalized: Bool) -> Double {
        useNormalized ? (cerNormalized ?? cer) : cer
    }
    func exactMatch(useNormalized: Bool) -> Bool {
        useNormalized ? (exactMatchNormalized ?? exactMatch) : exactMatch
    }
}

struct BenchmarkReport: Sendable, Codable {
    let modelID: String
    let chinesePreference: ChinesePreference
    let runAt: String               // ISO8601 timestamp
    let results: [BenchmarkResult]

    var total: Int { results.count }
    var completed: Int { results.filter { $0.error == nil }.count }
    var failed: Int { results.filter { $0.error != nil }.count }

    func exactMatchCount(useNormalized: Bool) -> Int {
        results.filter { $0.exactMatch(useNormalized: useNormalized) }.count
    }
    func exactMatchRate(useNormalized: Bool) -> Double {
        total == 0 ? 0 : Double(exactMatchCount(useNormalized: useNormalized)) / Double(total)
    }

    func averageCER(useNormalized: Bool) -> Double {
        let valid = results.filter { $0.error == nil }
        guard !valid.isEmpty else { return 0 }
        return valid.map { $0.cer(useNormalized: useNormalized) }.reduce(0, +) / Double(valid.count)
    }

    var averageLatencyMs: Int {
        let valid = results.filter { $0.error == nil }
        guard !valid.isEmpty else { return 0 }
        return valid.map(\.durationMs).reduce(0, +) / valid.count
    }
}

/// Sendable per-record progress callback payload.
struct BenchmarkProgress: Sendable {
    let completed: Int
    let total: Int
    let currentRecordID: String
}

/// Runs the full transcription pipeline (audio decode → model → post-process) against every
/// record in a dataset slice, comparing against the stored editedTranscript. Honors Task
/// cancellation between records.
actor BenchmarkRunner {
    func run(
        records: [DatasetRecord],
        runtime: any ASRRuntime,
        chinesePreference: ChinesePreference,
        audioURLProvider: @Sendable (DatasetRecord) async -> URL,
        progress: @Sendable (BenchmarkProgress) async -> Void = { _ in }
    ) async throws -> BenchmarkReport {
        var results: [BenchmarkResult] = []
        results.reserveCapacity(records.count)

        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            await progress(BenchmarkProgress(completed: index, total: records.count, currentRecordID: record.id))

            let audioURL = await audioURLProvider(record)
            let result = await transcribe(record: record, audioURL: audioURL, runtime: runtime, chinesePreference: chinesePreference)
            results.append(result)
        }

        try Task.checkCancellation()
        await progress(BenchmarkProgress(completed: records.count, total: records.count, currentRecordID: ""))

        let modelID = await runtime.modelID
        let runAt = ISO8601DateFormatter().string(from: Date())
        return BenchmarkReport(modelID: modelID, chinesePreference: chinesePreference, runAt: runAt, results: results)
    }

    private func transcribe(record: DatasetRecord, audioURL: URL, runtime: any ASRRuntime, chinesePreference: ChinesePreference) async -> BenchmarkResult {
        let groundTruth = record.editedTranscript
        let start = Date()

        // Decode audio → [Float] mirroring production pipeline.
        let samples: [Float]
        do {
            let (_, mlxArray) = try loadAudioArray(from: audioURL, sampleRate: 16000)
            samples = mlxArray.asArray(Float.self)
        } catch {
            return failure(record: record, groundTruth: groundTruth, error: error, start: start)
        }

        // Run the streaming pipeline end-to-end.
        var rawText = ""
        do {
            for try await event in runtime.transcribeStream(samples: samples, sampleRate: 16000, options: ASROptions(language: record.language)) {
                try Task.checkCancellation()
                switch event {
                case .token(let t):
                    rawText += t
                case .result(let r):
                    rawText = r.text  // final result overrides token-by-token concat
                }
            }
        } catch {
            return failure(record: record, groundTruth: groundTruth, error: error, start: start)
        }

        let editedText = TranscriptPostProcessor.apply(chinesePreference, to: rawText)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        let lightRef = TextMetrics.normalize(groundTruth, mode: .light)
        let lightHyp = TextMetrics.normalize(editedText, mode: .light)
        let lightDist = TextMetrics.editDistance(lightRef, lightHyp)
        let lightCER = lightRef.isEmpty ? (lightHyp.isEmpty ? 0 : 1) : Double(lightDist) / Double(lightRef.count)

        let aggrRef = TextMetrics.normalize(groundTruth, mode: .aggressive)
        let aggrHyp = TextMetrics.normalize(editedText, mode: .aggressive)
        let aggrDist = TextMetrics.editDistance(aggrRef, aggrHyp)
        let aggrCER = aggrRef.isEmpty ? (aggrHyp.isEmpty ? 0 : 1) : Double(aggrDist) / Double(aggrRef.count)

        return BenchmarkResult(
            id: record.id,
            recordCreatedAt: record.createdAt,
            groundTruth: groundTruth,
            predictedRaw: rawText,
            predictedEdited: editedText,
            editDistance: lightDist,
            referenceLength: lightRef.count,
            cer: lightCER,
            exactMatch: lightRef == lightHyp,
            editDistanceNormalized: aggrDist,
            referenceLengthNormalized: aggrRef.count,
            cerNormalized: aggrCER,
            exactMatchNormalized: aggrRef == aggrHyp,
            durationMs: elapsedMs,
            error: nil
        )
    }

    private func failure(record: DatasetRecord, groundTruth: String, error: Error, start: Date) -> BenchmarkResult {
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        return BenchmarkResult(
            id: record.id,
            recordCreatedAt: record.createdAt,
            groundTruth: groundTruth,
            predictedRaw: "",
            predictedEdited: "",
            editDistance: 0,
            referenceLength: groundTruth.count,
            cer: 0,
            exactMatch: false,
            editDistanceNormalized: 0,
            referenceLengthNormalized: groundTruth.count,
            cerNormalized: 0,
            exactMatchNormalized: false,
            durationMs: elapsedMs,
            error: String(describing: error)
        )
    }
}
