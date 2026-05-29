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

    func testAggressiveNormalizeStripsPunctuationCaseAndWidth() {
        // Punctuation + case fold
        XCTAssertEqual(TextMetrics.normalize("Hello, World!", mode: .aggressive), "hello world")
        // Full-width digits + letters fold to half-width
        XCTAssertEqual(TextMetrics.normalize("ＡＢＣ１２３", mode: .aggressive), "abc123")
        // CJK punctuation stripped, content preserved
        XCTAssertEqual(TextMetrics.normalize("你好，世界。", mode: .aggressive), "你好世界")
        // Quotes (curly + straight) stripped
        XCTAssertEqual(TextMetrics.normalize("\"It's\" — fine.", mode: .aggressive), "its fine")
    }

    func testAggressiveCERIgnoresCaseAndPunctuation() {
        // Strict: case + punctuation count as errors. Aggressive: zero.
        XCTAssertGreaterThan(TextMetrics.cer(reference: "Hello, World!", hypothesis: "hello world", mode: .light), 0)
        XCTAssertEqual(TextMetrics.cer(reference: "Hello, World!", hypothesis: "hello world", mode: .aggressive), 0, accuracy: 1e-9)
        // Substitution still counts under aggressive.
        XCTAssertEqual(
            TextMetrics.cer(reference: "abc", hypothesis: "abd", mode: .aggressive),
            1.0 / 3.0,
            accuracy: 1e-9
        )
    }

    func testAggressiveStripsCJKPunctuationExhaustive() {
        // Covers the common CJK punctuation set: ideographic comma/stop, corner brackets,
        // angle brackets, lenticular brackets, fullwidth ASCII punctuation, em dash, ellipsis,
        // middle dot, fullwidth tilde (symbol category). Should reduce to bare characters.
        let cjk = "你好、世界。「測試」『再測』（括號）【粗體】《書名》〈篇名〉；：！？—…·～"
        XCTAssertEqual(TextMetrics.normalize(cjk, mode: .aggressive), "你好世界測試再測括號粗體書名篇名")
    }

    func testAggressiveExactMatch() {
        XCTAssertTrue(TextMetrics.exactMatch(reference: "ABC.", hypothesis: "abc", mode: .aggressive))
        XCTAssertTrue(TextMetrics.exactMatch(reference: "你好，世界！", hypothesis: "你好世界", mode: .aggressive))
        XCTAssertFalse(TextMetrics.exactMatch(reference: "abc", hypothesis: "abd", mode: .aggressive))
    }

    // MARK: - WER

    func testWordTokensMixedScript() {
        // Latin words stay grouped; each CJK ideograph is its own token.
        XCTAssertEqual(TextMetrics.wordTokens("build a GitHub 網站"), ["build", "a", "GitHub", "網", "站"])
        // No spaces between CJK chars still splits per ideograph.
        XCTAssertEqual(TextMetrics.wordTokens("會議重點"), ["會", "議", "重", "點"])
        // Latin run with no spaces is a single token.
        XCTAssertEqual(TextMetrics.wordTokens("hello"), ["hello"])
        XCTAssertEqual(TextMetrics.wordTokens(""), [])
    }

    func testWERWordLevel() {
        // Identical → 0.
        XCTAssertEqual(TextMetrics.wer(reference: "the quick brown fox", hypothesis: "the quick brown fox"), 0)
        // 1 substituted word out of 4 → 1/4.
        XCTAssertEqual(
            TextMetrics.wer(reference: "the quick brown fox", hypothesis: "the quick green fox"),
            1.0 / 4.0,
            accuracy: 1e-9
        )
        // 1 inserted word: ref has 4 words, 1 insertion → 1/4.
        XCTAssertEqual(
            TextMetrics.wer(reference: "the quick brown fox", hypothesis: "the quick brown lazy fox"),
            1.0 / 4.0,
            accuracy: 1e-9
        )
        // Empty ref + empty hyp → 0; empty ref + non-empty hyp → 1.
        XCTAssertEqual(TextMetrics.wer(reference: "", hypothesis: ""), 0)
        XCTAssertEqual(TextMetrics.wer(reference: "", hypothesis: "x"), 1)
    }

    func testWERChineseTreatsEachCharAsWord() {
        // 4 ideograph "words", 1 substituted → 1/4. Mirrors CER for pure CJK by design.
        XCTAssertEqual(
            TextMetrics.wer(reference: "會議重點", hypothesis: "會議重論"),
            1.0 / 4.0,
            accuracy: 1e-9
        )
    }

    func testWERAggressiveIgnoresPunctuationAndCase() {
        // Light WER: trailing punctuation attaches to the word, so "fox" vs "fox." differ.
        XCTAssertGreaterThan(TextMetrics.wer(reference: "The Fox.", hypothesis: "the fox", mode: .light), 0)
        // Aggressive WER: punctuation + case folded away → identical.
        XCTAssertEqual(TextMetrics.wer(reference: "The Fox.", hypothesis: "the fox", mode: .aggressive), 0, accuracy: 1e-9)
    }
}
