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

    func testRejectsPostEditPayloadMissingAnyCanonicalKey() {
        let partialPayloads = [
            #"{"cjkLatinSpacing":true,"dictionary":[]}"#,
            #"{"chinese":"traditional","dictionary":[]}"#,
            #"{"chinese":"traditional","cjkLatinSpacing":true}"#
        ]

        for json in partialPayloads {
            XCTAssertThrowsError(
                try JSONDecoder().decode(PostEditConfig.self, from: Data(json.utf8))
            ) { error in
                guard case DecodingError.keyNotFound = error else {
                    return XCTFail("Expected keyNotFound for partial PostEditConfig, got \(error)")
                }
            }
        }
    }

    @MainActor
    func testModelManagerUsesDefaultsOnlyWhenCanonicalKeysAreUnsetAndIgnoresRetiredKey() throws {
        let suiteName = "TranscriptPostProcessorTests.ModelManager.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let modelsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkAloud-CanonicalPostEdit-\(UUID().uuidString)", isDirectory: true)
        let firstLaunchManager = try ModelManager(modelsDirectory: modelsDirectory, defaults: defaults)
        XCTAssertEqual(firstLaunchManager.profile, .accurate)
        XCTAssertEqual(firstLaunchManager.postEdit, .default)
        XCTAssertEqual(firstLaunchManager.preEdit, .default)
        XCTAssertEqual(firstLaunchManager.idleTimeout, .tenMinutes)

        defaults.set(ChinesePreference.traditional.rawValue, forKey: "ThinkAloud.chinesePreference")
        let managerWithRetiredKey = try ModelManager(modelsDirectory: modelsDirectory, defaults: defaults)
        XCTAssertEqual(managerWithRetiredKey.postEdit, .default)
    }

    @MainActor
    func testModelManagerRejectsEveryInvalidSavedCanonicalSetting() {
        let suiteName = "TranscriptPostProcessorTests.InvalidModelManager.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let modelsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkAloud-InvalidSettings-\(UUID().uuidString)", isDirectory: true)
        let cases: [(key: String, value: Any, expected: SavedSettingsError)] = [
            (
                "ThinkAloud.modelProfile",
                "retired-model",
                .invalidSavedValue(.speechModel)
            ),
            (
                "ThinkAloud.postEditConfig",
                Data(#"{"chinese":"traditional","cjkLatinSpacing":true}"#.utf8),
                .invalidSavedValue(.postEdit)
            ),
            (
                "ThinkAloud.preEditConfig",
                Data(#"{"denoise":true}"#.utf8),
                .invalidSavedValue(.preEdit)
            ),
            (
                "ThinkAloud.idleTimeout",
                "twoWeeks",
                .invalidSavedValue(.idleTimeout)
            )
        ]

        for testCase in cases {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(testCase.value, forKey: testCase.key)
            XCTAssertThrowsError(
                try ModelManager(modelsDirectory: modelsDirectory, defaults: defaults)
            ) { error in
                XCTAssertEqual(error as? SavedSettingsError, testCase.expected)
            }
        }
    }

    @MainActor
    func testModelManagerReadsCanonicalPostEditConfig() throws {
        let suiteName = "TranscriptPostProcessorTests.CanonicalModelManager.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let expected = PostEditConfig(
            chinese: .simplified,
            cjkLatinSpacing: true,
            dictionary: [DictionaryRule(from: "舊詞", to: "新詞")]
        )
        defaults.set(
            try JSONEncoder().encode(expected),
            forKey: "ThinkAloud.postEditConfig"
        )

        let modelsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkAloud-CanonicalPostEdit-\(UUID().uuidString)", isDirectory: true)
        let manager = try ModelManager(modelsDirectory: modelsDirectory, defaults: defaults)

        XCTAssertEqual(manager.postEdit, expected)
    }
}
