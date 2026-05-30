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

    // Word Error Rate (light = whitespace-only normalization, normalized = aggressive).
    // Optional for forward-compat with reports that predate the metric.
    let wer: Double?
    let werNormalized: Double?

    let durationMs: Int
    /// Decoded audio length in milliseconds. Drives RTF (processing ÷ audio). Optional for
    /// forward-compat and nil when audio decode failed.
    let audioDurationMs: Int?
    let error: String?

    var passed: Bool { error == nil }

    /// Pick the right metric tuple based on the user's display toggle. Falls back to the strict
    /// fields when an older report doesn't carry normalized values.
    func cer(useNormalized: Bool) -> Double {
        useNormalized ? (cerNormalized ?? cer) : cer
    }
    func wer(useNormalized: Bool) -> Double {
        useNormalized ? (werNormalized ?? 0) : (wer ?? 0)
    }
    func exactMatch(useNormalized: Bool) -> Bool {
        useNormalized ? (exactMatchNormalized ?? exactMatch) : exactMatch
    }
    /// Real-Time Factor: processing time ÷ audio length. nil when audio length is unknown.
    var rtf: Double? {
        guard let audioDurationMs, audioDurationMs > 0 else { return nil }
        return Double(durationMs) / Double(audioDurationMs)
    }
}

struct BenchmarkReport: Sendable, Codable {
    let modelID: String
    let preEdit: PreEditConfig
    let postEdit: PostEditConfig
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

    func averageWER(useNormalized: Bool) -> Double {
        let valid = results.filter { $0.error == nil }
        guard !valid.isEmpty else { return 0 }
        return valid.map { $0.wer(useNormalized: useNormalized) }.reduce(0, +) / Double(valid.count)
    }

    var averageLatencyMs: Int {
        let valid = results.filter { $0.error == nil }
        guard !valid.isEmpty else { return 0 }
        return valid.map(\.durationMs).reduce(0, +) / valid.count
    }

    /// Overall Real-Time Factor: total processing time ÷ total audio length across records with
    /// a known audio length. Weighting by audio length means long clips dominate (the standard
    /// throughput-style RTF) rather than each clip counting equally. nil when no record carries
    /// duration data (e.g. an older report), letting the UI show a placeholder.
    var averageRTF: Double? {
        let valid = results.filter { $0.error == nil && ($0.audioDurationMs ?? 0) > 0 }
        let totalAudioMs = valid.reduce(0) { $0 + ($1.audioDurationMs ?? 0) }
        guard totalAudioMs > 0 else { return nil }
        let totalProcessingMs = valid.reduce(0) { $0 + $1.durationMs }
        return Double(totalProcessingMs) / Double(totalAudioMs)
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
        postEdit: PostEditConfig,
        preEdit: PreEditConfig = .default,
        audioURLProvider: @Sendable (DatasetRecord) async -> URL,
        denoise: (@Sendable ([Float]) async throws -> [Float])? = nil,
        progress: @Sendable (BenchmarkProgress) async -> Void = { _ in }
    ) async throws -> BenchmarkReport {
        var results: [BenchmarkResult] = []
        results.reserveCapacity(records.count)

        for (index, record) in records.enumerated() {
            try Task.checkCancellation()
            await progress(BenchmarkProgress(completed: index, total: records.count, currentRecordID: record.id))

            let audioURL = await audioURLProvider(record)
            let result = await transcribe(record: record, audioURL: audioURL, runtime: runtime, postEdit: postEdit, denoiseMode: preEdit.denoise, denoise: preEdit.denoise != .off ? denoise : nil)
            results.append(result)
        }

        try Task.checkCancellation()
        await progress(BenchmarkProgress(completed: records.count, total: records.count, currentRecordID: ""))

        let modelID = await runtime.modelID
        let runAt = ISO8601DateFormatter().string(from: Date())
        return BenchmarkReport(modelID: modelID, preEdit: preEdit, postEdit: postEdit, runAt: runAt, results: results)
    }

    private func transcribe(record: DatasetRecord, audioURL: URL, runtime: any ASRRuntime, postEdit: PostEditConfig, denoiseMode: DenoiseMode, denoise: (@Sendable ([Float]) async throws -> [Float])?) async -> BenchmarkResult {
        let groundTruth = record.editedTranscript
        let start = Date()

        // Decode audio → [Float] mirroring production. When denoising is possible, decode at 48 kHz
        // (DeepFilterNet's rate); `.auto` runs the SAME heuristic as production on that 48 kHz band
        // and only enhances noisy clips; then resample to the 16 kHz the ASR model requires.
        let samples: [Float]
        let audioDurationMs: Int
        do {
            if let denoise, denoiseMode != .off {
                let (_, mlxArray) = try loadAudioArray(from: audioURL, sampleRate: 48000)
                let full = mlxArray.asArray(Float.self)
                audioDurationMs = Int(Double(full.count) / 48000.0 * 1000)
                let runDenoise = denoiseMode == .on
                    || DenoiseHeuristic.analyze(full, sampleRate: 48000).shouldDenoise
                let processed = runDenoise ? try await denoise(full) : full
                samples = try AudioRecorder.resample(processed, from: 48000, to: 16000)
            } else {
                let (sampleRate, mlxArray) = try loadAudioArray(from: audioURL, sampleRate: 16000)
                samples = mlxArray.asArray(Float.self)
                audioDurationMs = sampleRate > 0 ? Int(Double(samples.count) / Double(sampleRate) * 1000) : 0
            }
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

        let editedText = TranscriptPostProcessor.apply(postEdit, to: rawText)
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        let lightRef = TextMetrics.normalize(groundTruth, mode: .light)
        let lightHyp = TextMetrics.normalize(editedText, mode: .light)
        let lightDist = TextMetrics.editDistance(lightRef, lightHyp)
        let lightCER = lightRef.isEmpty ? (lightHyp.isEmpty ? 0 : 1) : Double(lightDist) / Double(lightRef.count)

        let aggrRef = TextMetrics.normalize(groundTruth, mode: .aggressive)
        let aggrHyp = TextMetrics.normalize(editedText, mode: .aggressive)
        let aggrDist = TextMetrics.editDistance(aggrRef, aggrHyp)
        let aggrCER = aggrRef.isEmpty ? (aggrHyp.isEmpty ? 0 : 1) : Double(aggrDist) / Double(aggrRef.count)

        let lightWER = TextMetrics.wer(reference: groundTruth, hypothesis: editedText, mode: .light)
        let aggrWER = TextMetrics.wer(reference: groundTruth, hypothesis: editedText, mode: .aggressive)

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
            wer: lightWER,
            werNormalized: aggrWER,
            durationMs: elapsedMs,
            audioDurationMs: audioDurationMs,
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
            wer: 0,
            werNormalized: 0,
            durationMs: elapsedMs,
            audioDurationMs: nil,
            error: String(describing: error)
        )
    }
}
