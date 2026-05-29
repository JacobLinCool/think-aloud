import XCTest
@testable import ThinkAloud

final class PreEditConfigTests: XCTestCase {
    func testDefaultIsInactive() {
        XCTAssertFalse(PreEditConfig.default.denoise)
        XCTAssertFalse(PreEditConfig.default.isActive)
    }

    func testIsActiveTracksDenoise() {
        XCTAssertTrue(PreEditConfig(denoise: true).isActive)
        XCTAssertFalse(PreEditConfig(denoise: false).isActive)
    }

    func testSummary() {
        XCTAssertEqual(PreEditConfig(denoise: false).summary, PreEditConfig(denoise: false).summary)
        XCTAssertNotEqual(PreEditConfig(denoise: true).summary, PreEditConfig(denoise: false).summary)
    }

    func testCodableRoundTrip() throws {
        let cfg = PreEditConfig(denoise: true)
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(PreEditConfig.self, from: data)
        XCTAssertEqual(cfg, decoded)
    }
}
