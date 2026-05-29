import XCTest
@testable import ThinkAloud

final class CJKLatinSpacerTests: XCTestCase {
    func testCJKBeforeLatin() {
        XCTAssertEqual(CJKLatinSpacer.spaced("中文A"), "中文 A")
    }

    func testLatinBeforeCJK() {
        XCTAssertEqual(CJKLatinSpacer.spaced("A中文"), "A 中文")
    }

    func testCJKAndDigits() {
        XCTAssertEqual(CJKLatinSpacer.spaced("第3版"), "第 3 版")
        XCTAssertEqual(CJKLatinSpacer.spaced("中文123"), "中文 123")
    }

    func testBothBoundariesInOneWord() {
        XCTAssertEqual(CJKLatinSpacer.spaced("用macOS看"), "用 macOS 看")
    }

    func testDoesNotDoubleExistingSpace() {
        XCTAssertEqual(CJKLatinSpacer.spaced("中文 A"), "中文 A")
        XCTAssertEqual(CJKLatinSpacer.spaced("A 中文"), "A 中文")
    }

    func testPureCJKUnchanged() {
        XCTAssertEqual(CJKLatinSpacer.spaced("這是一段中文"), "這是一段中文")
    }

    func testPureLatinUnchanged() {
        XCTAssertEqual(CJKLatinSpacer.spaced("ThinkAloud3"), "ThinkAloud3")
    }

    func testPunctuationActsAsSeparator() {
        // Punctuation between CJK and Latin is already a separator — no extra space is inserted
        // next to the parenthesis (v1 scope only spaces letter/digit ↔ CJK seams).
        XCTAssertEqual(CJKLatinSpacer.spaced("中文(English)"), "中文(English)")
    }

    func testEmptyString() {
        XCTAssertEqual(CJKLatinSpacer.spaced(""), "")
    }
}
