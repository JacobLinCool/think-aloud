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

    // MARK: - Canonical Codable contract

    func testRejectsLegacyBoolDenoiseValues() {
        for json in [#"{"denoise":true}"#, #"{"denoise":false}"#] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(PreEditConfig.self, from: Data(json.utf8))
            ) { error in
                guard case DecodingError.typeMismatch = error else {
                    return XCTFail("Expected typeMismatch for legacy Bool payload, got \(error)")
                }
            }
        }
    }

    func testDecodesNewEnumStrings() throws {
        func decode(_ s: String) throws -> DenoiseMode {
            try JSONDecoder().decode(PreEditConfig.self, from: s.data(using: .utf8)!).denoise
        }
        XCTAssertEqual(try decode(#"{"denoise":"off"}"#), .off)
        XCTAssertEqual(try decode(#"{"denoise":"auto"}"#), .auto)
        XCTAssertEqual(try decode(#"{"denoise":"on"}"#), .on)
    }

    func testRejectsMissingDenoiseKey() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(PreEditConfig.self, from: Data(#"{}"#.utf8))
        ) { error in
            guard case DecodingError.keyNotFound = error else {
                return XCTFail("Expected keyNotFound for incomplete canonical payload, got \(error)")
            }
        }
    }

    func testRejectsInvalidDenoiseValue() {
        for json in [#"{"denoise":42}"#, #"{"denoise":"automatic"}"#] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(PreEditConfig.self, from: Data(json.utf8))
            )
        }
    }

    func testCodableRoundTrip() throws {
        for mode in DenoiseMode.allCases {
            let cfg = PreEditConfig(denoise: mode)
            let decoded = try JSONDecoder().decode(PreEditConfig.self, from: JSONEncoder().encode(cfg))
            XCTAssertEqual(cfg, decoded)
        }
    }
}
