import XCTest
@testable import ThinkAloud

final class LLMConfigTests: XCTestCase {

    private func focus(_ bundleID: String?) -> FocusContext {
        FocusContext(appBundleID: bundleID, appName: bundleID, processID: nil, timestamp: Date(timeIntervalSince1970: 0))
    }

    // MARK: - effectiveConfig resolver

    func testPerAppOverrideWins() {
        var cfg = LLMPostEditConfig(defaultProfile: LLMProfileConfig(enabled: true, systemPrompt: "DEFAULT"))
        cfg.perApp["com.work.app"] = LLMProfileConfig(enabled: true, systemPrompt: "WORK")
        XCTAssertEqual(cfg.effectiveConfig(for: focus("com.work.app"))?.systemPrompt, "WORK")
    }

    func testUnknownAppFallsBackToDefault() {
        var cfg = LLMPostEditConfig(defaultProfile: LLMProfileConfig(enabled: true, systemPrompt: "DEFAULT"))
        cfg.perApp["com.work.app"] = LLMProfileConfig(enabled: true, systemPrompt: "WORK")
        XCTAssertEqual(cfg.effectiveConfig(for: focus("com.other.app"))?.systemPrompt, "DEFAULT")
    }

    func testNilBundleUsesDefault() {
        let cfg = LLMPostEditConfig(defaultProfile: LLMProfileConfig(enabled: true, systemPrompt: "DEFAULT"))
        XCTAssertEqual(cfg.effectiveConfig(for: focus(nil))?.systemPrompt, "DEFAULT")
        XCTAssertEqual(cfg.effectiveConfig(for: nil)?.systemPrompt, "DEFAULT")
    }

    func testDisabledDefaultReturnsNil() {
        let cfg = LLMPostEditConfig(defaultProfile: LLMProfileConfig(enabled: false))
        XCTAssertNil(cfg.effectiveConfig(for: focus("com.any.app")), "disabled default → no refine")
    }

    func testPerAppDisabledOverridesEnabledDefault() {
        var cfg = LLMPostEditConfig(defaultProfile: LLMProfileConfig(enabled: true, systemPrompt: "DEFAULT"))
        cfg.perApp["com.quiet.app"] = LLMProfileConfig(enabled: false)
        XCTAssertNil(cfg.effectiveConfig(for: focus("com.quiet.app")), "per-app off wins even if default is on")
        XCTAssertNotNil(cfg.effectiveConfig(for: focus("com.other.app")), "other apps still use the default")
    }

    func testIsAnyProfileEnabled() {
        XCTAssertFalse(LLMPostEditConfig.default.isAnyProfileEnabled)
        var cfg = LLMPostEditConfig.default
        cfg.perApp["com.x"] = LLMProfileConfig(enabled: true)
        XCTAssertTrue(cfg.isAnyProfileEnabled)
    }

    // MARK: - Canonical Codable contract

    func testRejectsLLMProfilePayloadMissingAnyCanonicalKey() {
        let partialProfiles = [
            #"{"backend":"mlx","systemPrompt":"HI","temperature":0.3}"#,
            #"{"enabled":true,"systemPrompt":"HI","temperature":0.3}"#,
            #"{"enabled":true,"backend":"mlx","temperature":0.3}"#,
            #"{"enabled":true,"backend":"mlx","systemPrompt":"HI"}"#
        ]

        for json in partialProfiles {
            XCTAssertThrowsError(
                try JSONDecoder().decode(LLMProfileConfig.self, from: Data(json.utf8))
            ) { error in
                guard case DecodingError.keyNotFound = error else {
                    return XCTFail("Expected keyNotFound for partial LLMProfileConfig, got \(error)")
                }
            }
        }
    }

    func testRejectsLLMPostEditPayloadMissingAnyCanonicalKey() {
        let profile = #"{"enabled":true,"backend":"mlx","systemPrompt":"HI","temperature":0.3}"#
        let partialPayloads = [
            #"{"perApp":{}}"#,
            #"{"defaultProfile":\#(profile)}"#
        ]

        for json in partialPayloads {
            XCTAssertThrowsError(
                try JSONDecoder().decode(LLMPostEditConfig.self, from: Data(json.utf8))
            ) { error in
                guard case DecodingError.keyNotFound = error else {
                    return XCTFail("Expected keyNotFound for partial LLMPostEditConfig, got \(error)")
                }
            }
        }
    }

    func testRoundTrip() throws {
        var cfg = LLMPostEditConfig(defaultProfile: LLMProfileConfig(enabled: true, backend: .appleFoundation, systemPrompt: "P", temperature: 0.7))
        cfg.perApp["com.a"] = LLMProfileConfig(enabled: true, systemPrompt: "A")
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(LLMPostEditConfig.self, from: data)
        XCTAssertEqual(cfg, back)
    }

    @MainActor
    func testLLMManagerUsesDefaultsOnlyWhenKeysAreUnset() throws {
        let suiteName = "LLMConfigTests.Unset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkAloud-LLMSettings-\(UUID().uuidString)", isDirectory: true)

        let manager = try LLMManager(cacheDirectory: cacheDirectory, defaults: defaults)

        XCTAssertEqual(manager.selectedModel, .recommended)
        XCTAssertEqual(manager.config, .default)
    }

    @MainActor
    func testLLMManagerRejectsEveryInvalidSavedCanonicalSetting() {
        let suiteName = "LLMConfigTests.Invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkAloud-InvalidLLMSettings-\(UUID().uuidString)", isDirectory: true)
        let cases: [(key: String, value: Any, expected: SavedSettingsError)] = [
            (
                "ThinkAloud.llmModelProfile",
                "retired-model",
                .invalidSavedValue(.refineModel)
            ),
            (
                "ThinkAloud.llmPostEditConfig",
                Data(#"{"defaultProfile":{"enabled":true}}"#.utf8),
                .invalidSavedValue(.refineConfiguration)
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
                try LLMManager(cacheDirectory: cacheDirectory, defaults: defaults)
            ) { error in
                XCTAssertEqual(error as? SavedSettingsError, testCase.expected)
            }
        }
    }

    @MainActor
    func testLLMManagerSurfacesEncodingFailureAndClearsItAfterSuccessfulSave() throws {
        let suiteName = "LLMConfigTests.Persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThinkAloud-LLMPersistence-\(UUID().uuidString)", isDirectory: true)
        let manager = try LLMManager(cacheDirectory: cacheDirectory, defaults: defaults)

        manager.config.defaultProfile.temperature = .nan
        XCTAssertEqual(manager.settingsError, .encodingFailed(.refineConfiguration))

        manager.config.defaultProfile.temperature = 0.3
        XCTAssertNil(manager.settingsError)
        XCTAssertNotNil(defaults.data(forKey: "ThinkAloud.llmPostEditConfig"))
    }

    func testInvalidSavedSettingsExposeOnlyTheirExactCanonicalRecoveryKey() {
        XCTAssertEqual(
            SavedSettingsError.invalidSavedValue(.speechModel).invalidPreferenceKey,
            "ThinkAloud.modelProfile"
        )
        XCTAssertEqual(
            SavedSettingsError.invalidSavedValue(.postEdit).invalidPreferenceKey,
            "ThinkAloud.postEditConfig"
        )
        XCTAssertEqual(
            SavedSettingsError.invalidSavedValue(.refineConfiguration).invalidPreferenceKey,
            "ThinkAloud.llmPostEditConfig"
        )
        XCTAssertNil(SavedSettingsError.encodingFailed(.postEdit).invalidPreferenceKey)
    }

    // MARK: - Reasoning strip (Qwen3 <think> blocks must never reach the editor/dataset)

    func testStripReasoning() {
        XCTAssertEqual(LLMText.stripReasoning("plain text"), "plain text")
        XCTAssertEqual(LLMText.stripReasoning("<think>reasoning here</think>The answer."), "The answer.")
        XCTAssertEqual(LLMText.stripReasoning("<think>still thinking, no answer yet"), "", "unclosed think → empty (no answer)")
        XCTAssertEqual(LLMText.stripReasoning("<think>a</think><think>b</think>Final"), "Final", "text after the LAST close")
        XCTAssertEqual(LLMText.stripReasoning("  <think>x</think>\n  Answer  "), "Answer", "trims around the answer")
        XCTAssertEqual(LLMText.stripReasoning(""), "")
    }

    // MARK: - Model profiles

    func testModelProfileLookupAndSizes() {
        XCTAssertEqual(LLMModelProfile.profile(forModelID: "mlx-community/Qwen3-1.7B-4bit"), .qwen3_1_7b)
        XCTAssertNil(LLMModelProfile.profile(forModelID: "nonexistent"))
        XCTAssertEqual(LLMModelProfile.recommended, .qwen3_1_7b)
        for p in LLMModelProfile.allCases {
            XCTAssertTrue(p.modelID.contains("/"), "valid HF id")
            XCTAssertFalse(p.estimatedDownloadSize.isEmpty)
        }
    }
}
