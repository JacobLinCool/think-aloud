import AVFoundation
import XCTest
@testable import ThinkAloud

final class AudioRecorderTests: XCTestCase {
    func testWriteWavFileProducesPlayableFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ThinkAloudTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("output.wav")
        let sampleRate: Double = 16000
        let durationSeconds: Double = 0.5
        let frameCount = Int(sampleRate * durationSeconds)
        let samples = (0..<frameCount).map { i -> Float in
            let t = Double(i) / sampleRate
            return Float(sin(2 * .pi * 440 * t)) * 0.5
        }
        try AudioRecorder.writeWavFile(samples: samples, sampleRate: sampleRate, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // Read it back and confirm format.
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Int(file.processingFormat.sampleRate), 16000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertGreaterThan(file.length, 0)
    }
}
