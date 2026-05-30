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
    private var timerTask: Task<Void, Never>?

    /// Captured at record time (it reaches into the MainActor ModelManager) so both the manual Stop
    /// and the safety auto-stop denoise the same way.
    private var denoiseFn: (_ samples: [Float]) async throws -> [Float] = { $0 }

    /// Capped so a forgotten recording can't grow unbounded; the heuristic only needs a couple
    /// seconds of speech + gaps.
    private let maxSeconds: TimeInterval = 12

    func startRecording(denoise: @escaping (_ samples: [Float]) async throws -> [Float]) {
        player.stop()
        denoiseFn = denoise
        decision = nil
        originalURL = nil
        denoisedURL = nil
        elapsed = 0
        phase = .recording
        Task { @MainActor in
            do {
                try await recorder.start()
            } catch {
                phase = .failed(error.localizedDescription)
                return
            }
        }
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while !Task.isCancelled, phase == .recording {
                try? await Task.sleep(nanoseconds: 200_000_000)
                elapsed = await recorder.elapsedSeconds
                if elapsed >= maxSeconds { stopAndProcess(); return }
            }
        }
    }

    func stopAndProcess() {
        guard phase == .recording else { return }
        let denoise = denoiseFn
        timerTask?.cancel()
        phase = .processing
        Task { @MainActor in
            do {
                let result = try await recorder.stop()
                guard !result.samples.isEmpty else {
                    phase = .failed(String(localized: "No audio was captured. Check microphone access and try again."))
                    return
                }
                decision = DenoiseHeuristic.analyze(result.samples, sampleRate: result.sampleRate)

                let dir = FileManager.default.temporaryDirectory
                let oURL = dir.appendingPathComponent("denoise-test-original.wav")
                try? FileManager.default.removeItem(at: oURL)
                try AudioRecorder.writeWavFile(samples: result.samples, sampleRate: Double(result.sampleRate), to: oURL)
                originalURL = oURL

                let denoised = try await denoise(result.samples)
                let dURL = dir.appendingPathComponent("denoise-test-denoised.wav")
                try? FileManager.default.removeItem(at: dURL)
                try AudioRecorder.writeWavFile(samples: denoised, sampleRate: 48000, to: dURL)
                denoisedURL = dURL

                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        timerTask?.cancel()
        player.stop()
        Task { await recorder.cancel() }
        phase = .idle
        decision = nil
    }
}
