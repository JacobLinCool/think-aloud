import XCTest
@testable import ThinkAloud

final class TranscriptPostProcessorTests: XCTestCase {
    func testModelPassesThrough() {
        let s = "这是模型生成的测试音讯。"
        XCTAssertEqual(TranscriptPostProcessor.apply(.model, to: s), s)
    }

    func testTraditional() {
        let s = "这是模型生成的测试音讯。"
        XCTAssertEqual(TranscriptPostProcessor.apply(.traditional, to: s), "這是模型生成的測試音訊。")
    }

    func testSimplified() {
        let s = "這是模型生成的測試音訊。"
        XCTAssertEqual(TranscriptPostProcessor.apply(.simplified, to: s), "这是模型生成的测试音讯。")
    }

    func testEnglishPassesThrough() {
        let s = "This is plain English."
        XCTAssertEqual(TranscriptPostProcessor.apply(.traditional, to: s), s)
        XCTAssertEqual(TranscriptPostProcessor.apply(.simplified, to: s), s)
    }

    func testMixedPreservesNonHan() {
        let s = "我用 macOS 看视频"
        let t = TranscriptPostProcessor.apply(.traditional, to: s)
        XCTAssertTrue(t.contains("macOS"))
        XCTAssertEqual(t, "我用 macOS 看視頻")
    }
}
