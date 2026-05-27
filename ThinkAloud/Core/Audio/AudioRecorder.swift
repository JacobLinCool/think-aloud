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
        case notRecording

        var errorDescription: String? {
            switch self {
            case .engineStartFailed(let msg): return "Audio engine failed to start: \(msg)"
            case .converterCreationFailed: return "Failed to create audio converter."
            case .formatUnsupported: return "Microphone audio format is unsupported."
            case .writerFailed(let msg): return "Failed to write WAV file: \(msg)"
            case .notRecording: return "No active recording."
            }
        }
    }

    struct LevelSample: Sendable {
        var rms: Float
        var peak: Float
        var timestamp: TimeInterval
    }

    private let targetSampleRate: Double = 16000
    private let engine = AVAudioEngine()
    private var outputBuffers: [Float] = []
    private var levelCallback: (@Sendable (LevelSample) -> Void)?
    private var startedAt: Date?
    private var isRecording: Bool = false

    func start(levelCallback: (@Sendable (LevelSample) -> Void)? = nil) async throws {
        if isRecording { return }
        outputBuffers.removeAll(keepingCapacity: true)
        self.levelCallback = levelCallback

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
        levelCallback = nil
    }

    var elapsedSeconds: TimeInterval {
        guard let startedAt else { return 0 }
        return -startedAt.timeIntervalSinceNow
    }

    fileprivate func ingest(chunk: ConvertedChunk) {
        outputBuffers.append(contentsOf: chunk.samples)
        if let levelCallback {
            let ts = startedAt.map { -$0.timeIntervalSinceNow } ?? 0
            levelCallback(LevelSample(rms: chunk.rms, peak: chunk.peak, timestamp: ts))
        }
    }

    fileprivate nonisolated static func convert(buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) -> ConvertedChunk? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return nil }

        // Use .noDataNow on subsequent callbacks instead of .endOfStream so the converter
        // does not flush/reset its internal state between buffers.
        var didProvide = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, statusPointer in
            if didProvide {
                statusPointer.pointee = .noDataNow
                return nil
            }
            didProvide = true
            statusPointer.pointee = .haveData
            return buffer
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
