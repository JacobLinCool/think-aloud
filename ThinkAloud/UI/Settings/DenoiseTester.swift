import AVFoundation
import SwiftUI

/// Drives the "test my environment" flow for Auto denoise: record a short mic sample, run the
/// gain-invariant `DenoiseHeuristic` to show whether Auto WOULD denoise (and why), then actually run
/// DeepFilterNet so the user can A/B the original vs. the cleaned audio. Uses its OWN AudioRecorder
/// (separate from the popup's) so it never disturbs a live dictation.
@MainActor
@Observable
final class DenoiseTester {
    enum Phase: Equatable {
        case idle
        case recording
        case processing   // analyzing + denoising (may download the denoiser on first use)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var decision: DenoiseDecision?
    private(set) var elapsed: TimeInterval = 0
    private(set) var originalURL: URL?
    private(set) var denoisedURL: URL?

    /// Reused for A/B so only one of original/denoised plays at a time.
    let player = AudioPlayerController()

    private let recorder = AudioRecorder()
    private var recordingStartTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    /// Invalidates late task completions after Reset or a new recording.
    private var generation = 0

    /// Captured at record time (it reaches into the MainActor ModelManager) so both the manual Stop
    /// and the safety auto-stop denoise the same way.
    private var denoiseFn: (_ samples: [Float]) async throws -> [Float] = { $0 }

    /// Capped so a forgotten recording can't grow unbounded; the heuristic only needs a couple
    /// seconds of speech + gaps.
    private let maxSeconds: TimeInterval = 12

    func startRecording(denoise: @escaping (_ samples: [Float]) async throws -> [Float]) {
        generation += 1
        let sessionGeneration = generation
        recordingStartTask?.cancel()
        processingTask?.cancel()
        timerTask?.cancel()
        player.stop()
        denoiseFn = denoise
        decision = nil
        originalURL = nil
        denoisedURL = nil
        elapsed = 0
        phase = .recording

        recordingStartTask = Task { @MainActor in
            defer {
                if self.generation == sessionGeneration {
                    self.recordingStartTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                try await recorder.start()
                try Task.checkCancellation()
            } catch is CancellationError {
                await recorder.cancel()
            } catch {
                guard self.generation == sessionGeneration else { return }
                NSLog("ThinkAloud: denoise test recording failed: \(error)")
                self.phase = .failed(
                    String(localized: "ThinkAloud couldn’t start the test recording. Check microphone access and the selected input, then try again.")
                )
            }
        }

        timerTask = Task { @MainActor in
            while !Task.isCancelled, phase == .recording {
                do {
                    try await Task.sleep(nanoseconds: 200_000_000)
                } catch {
                    return
                }
                guard generation == sessionGeneration else { return }
                elapsed = await recorder.elapsedSeconds
                if elapsed >= maxSeconds { stopAndProcess(); return }
            }
        }
    }

    func stopAndProcess() {
        guard phase == .recording else { return }
        let sessionGeneration = generation
        let startTask = recordingStartTask
        let denoise = denoiseFn
        timerTask?.cancel()
        timerTask = nil
        processingTask?.cancel()
        phase = .processing
        processingTask = Task { @MainActor in
            defer {
                if self.generation == sessionGeneration {
                    self.processingTask = nil
                }
            }
            do {
                await startTask?.value
                try Task.checkCancellation()
                guard self.generation == sessionGeneration, self.phase == .processing else { return }

                let result = try await recorder.stop()
                try Task.checkCancellation()
                guard !result.samples.isEmpty else {
                    self.phase = .failed(String(localized: "No audio was captured. Check microphone access and try again."))
                    return
                }
                self.decision = DenoiseHeuristic.analyze(result.samples, sampleRate: result.sampleRate)

                let dir = FileManager.default.temporaryDirectory
                let oURL = dir.appendingPathComponent("denoise-test-original.wav")
                try Self.writeWavReplacingExisting(
                    samples: result.samples,
                    sampleRate: Double(result.sampleRate),
                    to: oURL
                )
                self.originalURL = oURL

                let denoised = try await denoise(result.samples)
                try Task.checkCancellation()
                guard self.generation == sessionGeneration else { return }
                let dURL = dir.appendingPathComponent("denoise-test-denoised.wav")
                try Self.writeWavReplacingExisting(
                    samples: denoised,
                    sampleRate: 48_000,
                    to: dURL
                )
                try Task.checkCancellation()
                guard self.generation == sessionGeneration else { return }
                self.denoisedURL = dURL

                self.phase = .ready
            } catch is CancellationError {
                await recorder.cancel()
            } catch {
                guard self.generation == sessionGeneration else { return }
                NSLog("ThinkAloud: denoise test processing failed: \(error)")
                self.phase = .failed(
                    String(localized: "ThinkAloud couldn’t analyze or clean the test recording. Check Audio cleanup settings, then try again.")
                )
            }
        }
    }

    func reset() {
        generation += 1
        recordingStartTask?.cancel()
        recordingStartTask = nil
        processingTask?.cancel()
        processingTask = nil
        timerTask?.cancel()
        timerTask = nil
        player.stop()
        Task { await recorder.cancel() }
        phase = .idle
        decision = nil
        elapsed = 0
        originalURL = nil
        denoisedURL = nil
    }

    private static func writeWavReplacingExisting(
        samples: [Float],
        sampleRate: Double,
        to url: URL
    ) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try AudioRecorder.writeWavFile(samples: samples, sampleRate: sampleRate, to: url)
    }
}
