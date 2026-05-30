import XCTest
@testable import ThinkAloud

final class PreEditConfigTests: XCTestCase {
    func testDefaultIsOff() {
        XCTAssertEqual(PreEditConfig.default.denoise, .off)
        XCTAssertFalse(PreEditConfig.default.isActive)
    }

    func testIsActiveTracksMode() {
        XCTAssertFalse(PreEditConfig(denoise: .off).isActive)
        XCTAssertTrue(PreEditConfig(denoise: .auto).isActive)   // .auto MAY run DFN → potentially active
        XCTAssertTrue(PreEditConfig(denoise: .on).isActive)
    }

    func testSummaryDistinctPerMode() {
        let off = PreEditConfig(denoise: .off).summary
        let auto = PreEditConfig(denoise: .auto).summary
        let on = PreEditConfig(denoise: .on).summary
        XCTAssertNotEqual(off, auto)
        XCTAssertNotEqual(auto, on)
        XCTAssertNotEqual(off, on)
    }

    // MARK: - Codable back-compat (the load-bearing migration)

    func testDecodesLegacyBoolTrueAsOn() throws {
        // Pre-tri-state config stored `{"denoise": true}` (a Bool). Must migrate to .on, not reset.
        let data = #"{"denoise":true}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(PreEditConfig.self, from: data).denoise, .on)
    }

    func testDecodesLegacyBoolFalseAsOff() throws {
        let data = #"{"denoise":false}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(PreEditConfig.self, from: data).denoise, .off)
    }

    func testDecodesNewEnumStrings() throws {
        func decode(_ s: String) throws -> DenoiseMode {
            try JSONDecoder().decode(PreEditConfig.self, from: s.data(using: .utf8)!).denoise
        }
        XCTAssertEqual(try decode(#"{"denoise":"off"}"#), .off)
        XCTAssertEqual(try decode(#"{"denoise":"auto"}"#), .auto)
        XCTAssertEqual(try decode(#"{"denoise":"on"}"#), .on)
    }

    func testDecodesMissingOrGarbageAsOff() throws {
        XCTAssertEqual(try JSONDecoder().decode(PreEditConfig.self, from: #"{}"#.data(using: .utf8)!).denoise, .off)
        XCTAssertEqual(try JSONDecoder().decode(PreEditConfig.self, from: #"{"denoise":42}"#.data(using: .utf8)!).denoise, .off)
    }

    func testCodableRoundTrip() throws {
        for mode in DenoiseMode.allCases {
            let cfg = PreEditConfig(denoise: mode)
            let decoded = try JSONDecoder().decode(PreEditConfig.self, from: JSONEncoder().encode(cfg))
            XCTAssertEqual(cfg, decoded)
        }
    }
}
