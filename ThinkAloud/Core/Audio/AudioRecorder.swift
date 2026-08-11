import AVFoundation
import Accelerate
import Foundation

/// Sendable chunk extracted on the audio tap thread before being handed to the actor.
private struct ConvertedChunk: Sendable {
    let samples: [Float]
    let rms: Float
    let peak: Float
}

actor AudioRecorder {
    enum RecorderError: Error, LocalizedError {
        case engineStartFailed(String)
        case converterCreationFailed
        case formatUnsupported
        case writerFailed(String)
        case resampleFailed(String)
        case notRecording

        var errorDescription: String? {
            switch self {
            case .engineStartFailed:
                return String(
                    localized: "ThinkAloud couldn’t start the microphone. Check its connection and try again."
                )
            case .converterCreationFailed:
                return String(
                    localized: "ThinkAloud couldn’t prepare microphone audio. Reconnect the microphone and try again."
                )
            case .formatUnsupported:
                return String(
                    localized: "The microphone’s audio format isn’t supported. Choose another input device and try again."
                )
            case .writerFailed:
                return String(
                    localized: "ThinkAloud couldn’t create the recording file. Check available storage and try again."
                )
            case .resampleFailed:
                return String(
                    localized: "ThinkAloud couldn’t process the recording’s audio format. Record it again and retry."
                )
            case .notRecording:
                return String(localized: "There is no active recording to stop.")
            }
        }
    }

    struct LevelSample: Sendable {
        var rms: Float
        var peak: Float
        var timestamp: TimeInterval
    }

    // Capture at 48 kHz so the Auto Pre-Edit denoiser (DeepFilterNet, 48 kHz only) gets full-band
    // audio. ASR needs 16 kHz, so PopupCoordinator resamples to 16 kHz (via `resample`) before
    // transcribing. Saved dataset WAVs keep the 48 kHz fidelity; `loadAudioArray` resamples them
    // back to 16 kHz on benchmark/playback.
    // At 16-bit mono this uses about 5.76 MB per minute of recorded audio.
    private let targetSampleRate: Double = 48000
    private let engine = AVAudioEngine()
    private var outputBuffers: [Float] = []
    // Latest input level, overwritten on every tap buffer. Read (pulled) by the display loop
    // rather than pushed via a per-buffer callback — see `currentLevel` / `ingest`.
    private var lastRMS: Float = 0
    private var lastPeak: Float = 0
    private var startedAt: Date?
    private var isRecording: Bool = false

    func start() async throws {
        if isRecording { return }
        outputBuffers.removeAll(keepingCapacity: true)
        lastRMS = 0
        lastPeak = 0

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw RecorderError.formatUnsupported
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.converterCreationFailed
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterCreationFailed
        }

        // Capture sendable copies for use inside the audio tap.
        let capturedTargetFormat = targetFormat
        let capturedConverter = UncheckedSendableBox(value: converter)
        let recorderRef = self

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let chunk = AudioRecorder.convert(buffer: buffer, converter: capturedConverter.value, targetFormat: capturedTargetFormat) else { return }
            Task { await recorderRef.ingest(chunk: chunk) }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
        startedAt = Date()
        isRecording = true
    }

    func stop() async throws -> RecordingResult {
        guard isRecording else { throw RecorderError.notRecording }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        let started = startedAt ?? Date()
        // Drain a brief grace period so in-flight tap Tasks land in outputBuffers before we copy.
        try? await Task.sleep(nanoseconds: 60_000_000)
        let samples = outputBuffers
        outputBuffers.removeAll(keepingCapacity: false)
        let peak = samples.max(by: { abs($0) < abs($1) }).map(abs) ?? 0
        let duration = Double(samples.count) / targetSampleRate
        NSLog("ThinkAloud: AudioRecorder.stop samples=\(samples.count) peak=\(peak) duration=\(duration)s")
        return RecordingResult(
            samples: samples,
            sampleRate: Int(targetSampleRate),
            channels: 1,
            durationSeconds: duration,
            startedAt: started
        )
    }

    func cancel() async {
        if isRecording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRecording = false
        }
        outputBuffers.removeAll(keepingCapacity: false)
        startedAt = nil
        lastRMS = 0
        lastPeak = 0
    }

    var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return -startedAt.timeIntervalSinceNow
    }

    /// Latest computed input level. The popup's display loop pulls this at ~15Hz instead of the
    /// recorder pushing a MainActor Task per audio buffer (~47/s) — that push path was a major
    /// source of UI invalidation churn during recording.
    var currentLevel: LevelSample {
        LevelSample(rms: lastRMS, peak: lastPeak, timestamp: startedAt.map { -$0.timeIntervalSinceNow } ?? 0)
    }

    fileprivate func ingest(chunk: ConvertedChunk) {
        outputBuffers.append(contentsOf: chunk.samples)
        // Just stash the latest level; the display loop reads it on its own cadence.
        lastRMS = chunk.rms
        lastPeak = chunk.peak
    }

    fileprivate nonisolated static func convert(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) -> ConvertedChunk? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        // Use .noDataNow on subsequent callbacks instead of .endOfStream so the converter
        // does not flush/reset its internal state between buffers.
        let inputProvider = AudioConverterInputProvider(
            buffer: buffer,
            exhaustedStatus: .noDataNow
        )
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, statusPointer in
            inputProvider.nextBuffer(status: statusPointer)
        }
        if status == .error || error != nil {
            NSLog("ThinkAloud: AVAudioConverter failed: \(error?.localizedDescription ?? "unknown")")
            return nil
        }
        guard let channels = outBuffer.floatChannelData else { return nil }
        let count = Int(outBuffer.frameLength)
        if count == 0 { return nil }
        let pointer = channels[0]
        let samples = Array(UnsafeBufferPointer(start: pointer, count: count))

        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(count))
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(count))

        return ConvertedChunk(samples: samples, rms: rms, peak: peak)
    }

    /// One-shot sample-rate conversion of an in-memory mono Float clip (e.g. 48 kHz → 16 kHz
    /// before ASR). Returns the input unchanged only when the rates already match or the clip is
    /// empty. **Throws** `RecorderError.resampleFailed` on any conversion failure — callers must
    /// NOT proceed to feed the (still-source-rate) audio to the 16 kHz-only ASR runtimes.
    /// Unlike the live tap converter, this flushes with `.endOfStream` to drain all output.
    static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int) throws -> [Float] {
        guard sourceRate != targetRate, !samples.isEmpty else { return samples }
        guard
            let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sourceRate), channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(targetRate), channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw RecorderError.resampleFailed("setup failed (\(sourceRate)->\(targetRate))")
        }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = inBuffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channel[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        let ratio = Double(targetRate) / Double(sourceRate)
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw RecorderError.resampleFailed("output buffer allocation failed")
        }

        let inputProvider = AudioConverterInputProvider(
            buffer: inBuffer,
            exhaustedStatus: .endOfStream
        )
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, statusPointer in
            inputProvider.nextBuffer(status: statusPointer)
        }
        if status == .error || error != nil {
            throw RecorderError.resampleFailed(error?.localizedDescription ?? "conversion error")
        }
        guard let channel = outBuffer.floatChannelData, outBuffer.frameLength > 0 else {
            throw RecorderError.resampleFailed("no output produced")
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(outBuffer.frameLength)))
    }

    static func writeWavFile(samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw RecorderError.writerFailed("invalid format")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw RecorderError.writerFailed(error.localizedDescription)
        }

        let chunkSize = 4096
        var index = 0
        while index < samples.count {
            let upper = min(index + chunkSize, samples.count)
            let length = AVAudioFrameCount(upper - index)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else {
                throw RecorderError.writerFailed("buffer alloc")
            }
            buffer.frameLength = length
            if let channel = buffer.floatChannelData {
                samples.withUnsafeBufferPointer { src in
                    channel[0].update(from: src.baseAddress!.advanced(by: index), count: Int(length))
                }
            }
            do {
                try file.write(from: buffer)
            } catch {
                throw RecorderError.writerFailed(error.localizedDescription)
            }
            index = upper
        }
    }
}

struct RecordingResult: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let channels: Int
    let durationSeconds: Double
    let startedAt: Date

    var durationMs: Int { Int(durationSeconds * 1000) }
}

/// Wraps a non-Sendable reference type so it can cross isolation boundaries when the caller guarantees safety.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
}

/// Owns the one-shot input state used by `AVAudioConverter`'s `@Sendable` callback.
///
/// AVFoundation invokes the callback synchronously today, but the lock makes the single-delivery
/// contract explicit and safe even if that implementation detail changes. The buffer is immutable
/// for the lifetime of one conversion and is never exposed after the converter returns.
private final class AudioConverterInputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private let exhaustedStatus: AVAudioConverterInputStatus
    private var didProvideBuffer = false

    init(buffer: AVAudioPCMBuffer, exhaustedStatus: AVAudioConverterInputStatus) {
        self.buffer = buffer
        self.exhaustedStatus = exhaustedStatus
    }

    func nextBuffer(
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard !didProvideBuffer else {
            status.pointee = exhaustedStatus
            return nil
        }
        didProvideBuffer = true
        status.pointee = .haveData
        return buffer
    }
}
