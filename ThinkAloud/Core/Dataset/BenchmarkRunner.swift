import Foundation
import MLX
import MLXAudioCore

struct BenchmarkResult: Sendable, Identifiable, Codable, Equatable {
    let id: String                  // record id
    let recordCreatedAt: String
    let groundTruth: String         // record.editedTranscript at run time (treated as ground truth)
    let predictedRaw: String        // model output before post-process
    let predictedEdited: String     // after TranscriptPostProcessor (final pipeline output)
    let editDistance: Int
    let referenceLength: Int
    let cer: Double
    let exactMatch: Bool
    let durationMs: Int
    let error: String?

    var passed: Bool { error == nil }
}

struct BenchmarkReport: Sendable, Codable {
    let modelID: String
    let chinesePreference: ChinesePreference
    let runAt: String               // ISO8601 timestamp
    let results: [BenchmarkResult]

    var total: Int { results.count }
    var completed: Int { results.filter { $0.error == nil }.count }
    var failed: Int { results.filter { $0.error != nil }.count }
    var exactMatchCount: Int { results.filter { $0.exactMatch }.count }
    var exactMatchRate: Double { total == 0 ? 0 : Double(exactMatchCount) / Double(total) }

    var averageCER: Double {
        let valid = results.filter { $0.error == nil }
        guard !valid.isEmpty else { return 0 }
        return valid.map(\.cer).reduce(0, +) / Double(valid.count)
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

        let normalizedRef = TextMetrics.normalize(groundTruth)
        let normalizedHyp = TextMetrics.normalize(editedText)
        let dist = TextMetrics.editDistance(normalizedRef, normalizedHyp)
        let cer = normalizedRef.isEmpty ? (normalizedHyp.isEmpty ? 0 : 1) : Double(dist) / Double(normalizedRef.count)

        return BenchmarkResult(
            id: record.id,
            recordCreatedAt: record.createdAt,
            groundTruth: groundTruth,
            predictedRaw: rawText,
            predictedEdited: editedText,
            editDistance: dist,
            referenceLength: normalizedRef.count,
            cer: cer,
            exactMatch: normalizedRef == normalizedHyp,
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
            durationMs: elapsedMs,
            error: String(describing: error)
        )
    }
}
