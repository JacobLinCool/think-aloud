import Foundation

struct SmokeTestSample: Sendable, Identifiable, Equatable {
    let id: String
    let audioURL: URL
    let referenceText: String
    let language: String?
}

struct SmokeTestResult: Sendable, Identifiable, Equatable {
    let id: String
    let sample: SmokeTestSample
    let transcript: String         // raw output from the model
    let editedTranscript: String   // after TranscriptPostProcessor (Auto Post-Edit applied)
    let durationMs: Int
    let error: String?
    var passed: Bool { error == nil && !transcript.isEmpty }
}

struct SmokeTestReport: Sendable {
    let modelID: String
    let postEdit: PostEditConfig
    let results: [SmokeTestResult]
    var passed: Int { results.filter(\.passed).count }
    var total: Int { results.count }
    var averageLatencyMs: Int {
        guard !results.isEmpty else { return 0 }
        return results.map(\.durationMs).reduce(0, +) / results.count
    }
}

enum SmokeTestError: LocalizedError {
    case cacheCreationFailed(URL, Error)
    case invalidSampleURL(String)
    case downloadRequestFailed(String, Error)
    case downloadFailed(String, Int)
    case sampleWriteFailed(String, Error)
    case transcriptionFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .cacheCreationFailed:
            return String(
                localized: "ThinkAloud couldn’t prepare the model-test folder. Check available storage and folder permissions, then try again."
            )
        case .invalidSampleURL(let filename):
            return String(
                localized: "The test-audio address for \(filename) is invalid. Update ThinkAloud and try again."
            )
        case .downloadRequestFailed(let filename, _):
            return String(
                localized: "ThinkAloud couldn’t download \(filename). Check your internet connection and try again."
            )
        case .downloadFailed(let filename, _):
            return String(
                localized: "ThinkAloud couldn’t download \(filename). Check your internet connection and try again."
            )
        case .sampleWriteFailed(let filename, _):
            return String(
                localized: "ThinkAloud couldn’t save \(filename) in the model-test folder. Check available storage and try again."
            )
        case .transcriptionFailed(let sampleID, _):
            return String(
                localized: "ThinkAloud couldn’t transcribe test sample \(sampleID). Check the model status and retry."
            )
        }
    }
}

/// Runs JacobLinCool/audio-testing smoke test using the configured ASR runtime.
/// Audio samples are downloaded once into a local cache directory.
actor SmokeTestRunner {
    private let cacheDirectory: URL
    private let urlSession: URLSession

    init(cacheDirectory: URL, urlSession: URLSession = .shared) throws {
        self.cacheDirectory = cacheDirectory
        self.urlSession = urlSession
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            throw SmokeTestError.cacheCreationFailed(cacheDirectory, error)
        }
    }

    /// Runs the full transcription pipeline: model inference + Auto Post-Edit post-processing.
    /// Mirrors what the popup does after a real recording, so users can verify both stages from Settings.
    func run(using runtime: any ASRRuntime, postEdit: PostEditConfig = .default) async throws -> SmokeTestReport {
        try Task.checkCancellation()
        let samples = try await ensureSamples()
        var results: [SmokeTestResult] = []
        for sample in samples {
            try Task.checkCancellation()
            do {
                let result = try await runtime.transcribe(audioURL: sample.audioURL, options: ASROptions(language: sample.language))
                try Task.checkCancellation()
                let edited = TranscriptPostProcessor.apply(postEdit, to: result.text)
                results.append(SmokeTestResult(id: sample.id, sample: sample, transcript: result.text, editedTranscript: edited, durationMs: result.durationMs, error: nil))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                NSLog("ThinkAloud: model test transcription failed for \(sample.id): \(error)")
                let message = SmokeTestError.transcriptionFailed(sample.id, error).localizedDescription
                results.append(SmokeTestResult(id: sample.id, sample: sample, transcript: "", editedTranscript: "", durationMs: 0, error: message))
            }
        }
        let modelID = runtime.modelID
        return SmokeTestReport(modelID: modelID, postEdit: postEdit, results: results)
    }

    private func ensureSamples() async throws -> [SmokeTestSample] {
        // JacobLinCool/audio-testing dataset manifest (see audio/metadata.jsonl on the dataset page).
        let manifest: [(id: String, filename: String, lang: String?, text: String)] = [
            ("audio_testing_en_1", "audio-1.mp3", "English", "This is a test audio generated by the model."),
            ("audio_testing_zh_2", "audio-2.mp3", "Chinese", "這是模型生成的測試音訊。"),
            ("audio_testing_zh_3", "audio-3.wav", "Chinese", "這是模型生成的 wav 格式測試音訊。")
        ]

        var samples: [SmokeTestSample] = []
        for entry in manifest {
            try Task.checkCancellation()
            let localURL = cacheDirectory.appendingPathComponent(entry.filename)
            if !FileManager.default.fileExists(atPath: localURL.path) {
                guard let remote = URL(
                    string: "https://huggingface.co/datasets/JacobLinCool/audio-testing/resolve/main/audio/\(entry.filename)"
                ) else {
                    throw SmokeTestError.invalidSampleURL(entry.filename)
                }
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await urlSession.data(from: remote)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw SmokeTestError.downloadRequestFailed(entry.filename, error)
                }
                try Task.checkCancellation()
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw SmokeTestError.downloadFailed(entry.filename, http.statusCode)
                }
                do {
                    try data.write(to: localURL, options: .atomic)
                } catch {
                    throw SmokeTestError.sampleWriteFailed(entry.filename, error)
                }
            }
            samples.append(SmokeTestSample(id: entry.id, audioURL: localURL, referenceText: entry.text, language: entry.lang))
        }
        return samples
    }
}
