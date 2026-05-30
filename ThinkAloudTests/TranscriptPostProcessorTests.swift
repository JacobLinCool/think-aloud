import XCTest
@testable import ThinkAloud

final class TranscriptPostProcessorTests: XCTestCase {
    // MARK: - Chinese conversion step

    func testModelPassesThrough() {
        let s = "这是模型生成的测试音讯。"
        XCTAssertEqual(TranscriptPostProcessor.apply(PostEditConfig(chinese: .model), to: s), s)
    }

    func testTraditional() {
        let s = "这是模型生成的测试音讯。"
        XCTAssertEqual(TranscriptPostProcessor.apply(PostEditConfig(chinese: .traditional), to: s), "這是模型生成的測試音訊。")
    }

    func testSimplified() {
        let s = "這是模型生成的測試音訊。"
        XCTAssertEqual(TranscriptPostProcessor.apply(PostEditConfig(chinese: .simplified), to: s), "这是模型生成的测试音讯。")
    }

    func testEnglishPassesThrough() {
        let s = "This is plain English."
        XCTAssertEqual(TranscriptPostProcessor.apply(PostEditConfig(chinese: .traditional), to: s), s)
        XCTAssertEqual(TranscriptPostProcessor.apply(PostEditConfig(chinese: .simplified), to: s), s)
    }

    func testMixedPreservesNonHan() {
        let s = "我用 macOS 看视频"
        let t = TranscriptPostProcessor.apply(PostEditConfig(chinese: .traditional), to: s)
        XCTAssertTrue(t.contains("macOS"))
        XCTAssertEqual(t, "我用 macOS 看視頻")
    }

    // MARK: - Default + pipeline composition

    func testDefaultIsNoOp() {
        let s = "测试 ThinkAloud3"
        XCTAssertEqual(TranscriptPostProcessor.apply(.default, to: s), s)
    }

    func testSpacingOnlyWhenEnabled() {
        let s = "測試ThinkAloud"
        XCTAssertEqual(TranscriptPostProcessor.apply(PostEditConfig(chinese: .model, cjkLatinSpacing: false), to: s), s)
        XCTAssertEqual(TranscriptPostProcessor.apply(PostEditConfig(chinese: .model, cjkLatinSpacing: true), to: s), "測試 ThinkAloud")
    }

    func testChineseConversionThenSpacing() {
        // Simplified input → traditional conversion first, then CJK/Latin spacing inserts the gap.
        let s = "测试macOS"
        let t = TranscriptPostProcessor.apply(PostEditConfig(chinese: .traditional, cjkLatinSpacing: true), to: s)
        XCTAssertEqual(t, "測試 macOS")
    }

    // MARK: - Config

    func testSummaryReflectsActiveSteps() {
        XCTAssertEqual(PostEditConfig(chinese: .model, cjkLatinSpacing: false).summary,
                       ChinesePreference.model.displayName)
        XCTAssertTrue(PostEditConfig(chinese: .traditional, cjkLatinSpacing: true).summary.contains("·"))
    }

    func testCodableRoundTrip() throws {
        let cfg = PostEditConfig(chinese: .simplified, cjkLatinSpacing: true,
                                 dictionary: [DictionaryRule(from: "gpt四", to: "GPT-4")])
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(PostEditConfig.self, from: data)
        XCTAssertEqual(cfg, decoded)
    }

    // MARK: - Dictionary as the last pipeline step

    func testDictionaryRunsAfterChineseConversion() {
        // Simplified conversion turns 歐拉 → 欧拉 first; the rule (authored in Simplified) then matches.
        let cfg = PostEditConfig(chinese: .simplified, cjkLatinSpacing: false,
                                 dictionary: [DictionaryRule(from: "欧拉", to: "Euler")])
        XCTAssertEqual(TranscriptPostProcessor.apply(cfg, to: "歐拉公式"), "Euler公式")
    }

    func testSpacingSplitsDictionaryPatternWhenEnabled() {
        // Documents the ordering trap: with spacing ON, 用gpt四 → 用 gpt 四 BEFORE the dictionary,
        // so a rule `gpt四`→`GPT-4` no longer matches. A future apply() reorder would break this.
        let cfg = PostEditConfig(chinese: .model, cjkLatinSpacing: true,
                                 dictionary: [DictionaryRule(from: "gpt四", to: "GPT-4")])
        XCTAssertEqual(TranscriptPostProcessor.apply(cfg, to: "用gpt四"), "用 gpt 四")
        // With spacing OFF the same rule fires.
        let off = PostEditConfig(chinese: .model, cjkLatinSpacing: false,
                                 dictionary: [DictionaryRule(from: "gpt四", to: "GPT-4")])
        XCTAssertEqual(TranscriptPostProcessor.apply(off, to: "用gpt四"), "用GPT-4")
    }

    func testDecodesLegacyJSONWithoutDictionaryKey() throws {
        // Pre-dictionary persisted config must still load (no keyNotFound), preserving cjkLatinSpacing.
        let legacy = #"{"chinese":"traditional","cjkLatinSpacing":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PostEditConfig.self, from: legacy)
        XCTAssertEqual(decoded.chinese, .traditional)
        XCTAssertTrue(decoded.cjkLatinSpacing)
        XCTAssertTrue(decoded.dictionary.isEmpty)
    }
}
