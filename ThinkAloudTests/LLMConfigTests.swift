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

    // MARK: - Codable migration (decodeIfPresent — partial JSON never resets settings)

    func testPartialJSONDecodesWithDefaults() throws {
        // Older/partial payload missing newer keys must not throw — it should fill defaults.
        let json = #"{"defaultProfile":{"enabled":true,"systemPrompt":"HI"}}"#.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(LLMPostEditConfig.self, from: json)
        XCTAssertTrue(cfg.defaultProfile.enabled)
        XCTAssertEqual(cfg.defaultProfile.systemPrompt, "HI")
        XCTAssertEqual(cfg.defaultProfile.backend, .mlx, "missing backend → default .mlx")
        XCTAssertEqual(cfg.defaultProfile.temperature, 0.3, accuracy: 1e-9)
        XCTAssertTrue(cfg.perApp.isEmpty, "missing perApp → empty")
    }

    func testRoundTrip() throws {
        var cfg = LLMPostEditConfig(defaultProfile: LLMProfileConfig(enabled: true, backend: .appleFoundation, systemPrompt: "P", temperature: 0.7))
        cfg.perApp["com.a"] = LLMProfileConfig(enabled: true, systemPrompt: "A")
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(LLMPostEditConfig.self, from: data)
        XCTAssertEqual(cfg, back)
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
