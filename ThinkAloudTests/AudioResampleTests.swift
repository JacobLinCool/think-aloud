import XCTest
@testable import ThinkAloud

final class AudioResampleTests: XCTestCase {
    func testEqualRateIsPassthrough() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        XCTAssertEqual(try AudioRecorder.resample(samples, from: 16000, to: 16000), samples)
    }

    func testEmptyStaysEmpty() throws {
        XCTAssertEqual(try AudioRecorder.resample([], from: 48000, to: 16000), [])
    }

    func testDownsample48to16ApproximatelyOneThirdLength() throws {
        // 1 second of 48 kHz audio → ~16000 samples at 16 kHz.
        let oneSecond = [Float](repeating: 0, count: 48000)
        let out = try AudioRecorder.resample(oneSecond, from: 48000, to: 16000)
        XCTAssertFalse(out.isEmpty, "resampling should produce output")
        // Allow generous tolerance for converter priming/flush frames.
        XCTAssertEqual(Double(out.count), 16000, accuracy: 1600,
                       "expected ~16000 samples, got \(out.count)")
    }

    func testUpsample16to48ApproximatelyTripleLength() throws {
        let quarterSecond = [Float](repeating: 0, count: 4000) // 0.25s @ 16kHz
        let out = try AudioRecorder.resample(quarterSecond, from: 16000, to: 48000)
        XCTAssertEqual(Double(out.count), 12000, accuracy: 1200,
                       "expected ~12000 samples, got \(out.count)")
    }
}
