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
        let cfg = PostEditConfig(chinese: .simplified, cjkLatinSpacing: true)
        let data = try JSONEncoder().encode(cfg)
        let decoded = try JSONDecoder().decode(PostEditConfig.self, from: data)
        XCTAssertEqual(cfg, decoded)
    }
}
