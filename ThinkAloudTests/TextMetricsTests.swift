import XCTest
@testable import ThinkAloud

final class TextMetricsTests: XCTestCase {
    func testEditDistanceBasics() {
        XCTAssertEqual(TextMetrics.editDistance("", ""), 0)
        XCTAssertEqual(TextMetrics.editDistance("abc", ""), 3)
        XCTAssertEqual(TextMetrics.editDistance("", "abc"), 3)
        XCTAssertEqual(TextMetrics.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(TextMetrics.editDistance("abc", "abc"), 0)
    }

    func testEditDistanceChineseCharacters() {
        XCTAssertEqual(TextMetrics.editDistance("會議重點", "會議結論"), 2)
        XCTAssertEqual(TextMetrics.editDistance("這是測試", "這是測試"), 0)
        XCTAssertEqual(TextMetrics.editDistance("這是測試", "這是錯誤的測試"), 3)
    }

    func testCERIsLengthNormalized() {
        // Perfect match → 0
        XCTAssertEqual(TextMetrics.cer(reference: "abc", hypothesis: "abc"), 0)
        // 1 substitution out of 3 chars → 1/3
        XCTAssertEqual(TextMetrics.cer(reference: "abc", hypothesis: "abd"), 1.0 / 3.0, accuracy: 1e-9)
        // Empty ref + empty hyp → 0; empty ref + non-empty hyp → 1
        XCTAssertEqual(TextMetrics.cer(reference: "", hypothesis: ""), 0)
        XCTAssertEqual(TextMetrics.cer(reference: "", hypothesis: "x"), 1)
    }

    func testNormalizeTrimsAndCollapsesWhitespace() {
        XCTAssertEqual(TextMetrics.normalize("  hello   world  "), "hello world")
        XCTAssertEqual(TextMetrics.normalize("中文\n\t  混雜"), "中文 混雜")
    }

    func testExactMatchIgnoresEdgeWhitespace() {
        XCTAssertTrue(TextMetrics.exactMatch(reference: "abc  ", hypothesis: "abc"))
        XCTAssertTrue(TextMetrics.exactMatch(reference: "hello   world", hypothesis: "hello world"))
        XCTAssertFalse(TextMetrics.exactMatch(reference: "abc", hypothesis: "Abc"))
    }
}
