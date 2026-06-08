import Foundation

/// Availability gate + factory for the Apple Intelligence (FoundationModels) backend. Everything
/// FoundationModels-specific is isolated behind `#if canImport(FoundationModels)` + `@available`, so
/// the app keeps its macOS 15.0 deployment floor: on an SDK without FoundationModels (the macOS-15 CI
/// runner) this whole backend compiles out and `isAvailable` is simply false. It therefore only ships
/// active once the release toolchain is on the macOS 26 SDK.
enum AppleFoundationAvailability {
    /// True only when FoundationModels is present AND the on-device model is actually usable (Apple
    /// Intelligence enabled, eligible device, supported region).
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleFoundationLLMRuntime.systemAvailable
        }
        #endif
        return false
    }

    /// A one-line reason the backend is unavailable, for the Settings UI. nil when available.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleFoundationLLMRuntime.unavailableReason
        }
        return String(localized: "Requires macOS 26 or later.")
        #else
        return String(localized: "This build was compiled without Apple Intelligence support.")
        #endif
    }

    static func makeRuntime() -> any LLMRuntime {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return AppleFoundationLLMRuntime()
        }
        #endif
        return UnavailableLLMRuntime()
    }
}

/// Fail-open stub used when Apple Intelligence isn't available — yields nothing, so the caller keeps
/// the deterministic transcript.
struct UnavailableLLMRuntime: LLMRuntime {
    let modelID = "apple-foundation-unavailable"
    func status() async -> ASRRuntimeStatus { .failed("Apple Intelligence is unavailable.") }
    func preload() async throws {}
    func refine(_ transcript: String, instructions: String, params: LLMGenerateParams) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func unload() async {}
}

#if canImport(FoundationModels)
import FoundationModels

/// Apple Intelligence on-device LLM backend. No download; refine() runs a single prompt and yields
/// the result once. Fails OPEN — on guardrail refusal, context overflow, or unavailability it yields
/// nothing and finishes, so the popup keeps the deterministic Auto-Post-Edit output as the floor.
@available(macOS 26.0, *)
final class AppleFoundationLLMRuntime: LLMRuntime {
    let modelID = "apple-foundation-models"

    static var systemAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return String(localized: "This Mac isn't eligible for Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Turn on Apple Intelligence in System Settings.")
        case .unavailable(.modelNotReady):
            return String(localized: "The Apple Intelligence model is still downloading.")
        case .unavailable:
            return String(localized: "Apple Intelligence isn't available right now.")
        }
    }

    func status() async -> ASRRuntimeStatus {
        Self.systemAvailable ? .ready : .failed(Self.unavailableReason ?? "unavailable")
    }

    func preload() async throws {}
    func unload() async {}

    nonisolated func refine(_ transcript: String, instructions: String, params: LLMGenerateParams) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: transcript)
                    if Task.isCancelled { continuation.finish(); return }
                    continuation.yield(response.content)
                    continuation.finish()
                } catch {
                    // Fail open: refusal / context overflow / unavailable → keep deterministic text.
                    NSLog("ThinkAloud: Apple Intelligence refine failed open: \(error)")
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
