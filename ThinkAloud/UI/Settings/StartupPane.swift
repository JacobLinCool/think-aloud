import AppKit
import SwiftUI

/// Settings → Startup: app-level "set once" preferences (interface language; Open at login arrives
/// in a later phase). Lifted verbatim from the old General pane — same @AppStorage key and bindings.
struct StartupPane: View {
    /// Persists the user's explicit language choice. Kept separate from `AppleLanguages` (which
    /// always carries a resolved list, so it can't tell "user picked system" from "no choice yet").
    @AppStorage(AppLanguage.storageKey) private var languageSelection = AppLanguage.system.rawValue
    /// True once the picker is touched this session, so we surface the relaunch hint.
    @State private var languageChanged = false

    private var languageBinding: Binding<AppLanguage> {
        Binding(
            get: { AppLanguage(rawValue: languageSelection) ?? .system },
            set: { newValue in
                guard newValue.rawValue != languageSelection else { return }
                languageSelection = newValue.rawValue
                newValue.applyBundleOverride()
                languageChanged = true
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Picker("App language", selection: languageBinding) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(verbatim: lang.displayName).tag(lang)
                    }
                }
                if languageChanged {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Restart to apply the new language.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(String(localized: "Relaunch now")) {
                            AppLanguage.relaunch()
                        }
                        .controlSize(.small)
                    }
                }
            } header: {
                Text("Language")
            } footer: {
                Text("Sets the app's interface language — not the transcription output. Automatic follows your system language. Changes take effect after relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// User-selectable UI language. `.system` defers to the OS language order; the others pin the app
/// to one localization by writing the per-app `AppleLanguages` default, which the bundle's string
/// loader reads at launch — hence changes only take full effect after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case traditionalChinese

    var id: String { rawValue }

    /// UserDefaults key for the user's explicit choice.
    static let storageKey = "appLanguageSelection"

    /// Code written into `AppleLanguages`. nil for `.system` (override removed → follow system).
    private var localeCode: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .traditionalChinese: return "zh-Hant"
        }
    }

    /// Shown in its own language so the option stays recognizable regardless of the current UI
    /// language. `.system` is the exception — it reads as a localized "Automatic" label.
    var displayName: String {
        switch self {
        case .system: return String(localized: "Automatic (system)")
        case .english: return "English"
        case .traditionalChinese: return "正體中文"
        }
    }

    /// Sets or clears the per-app `AppleLanguages` override. Written immediately, so even a plain
    /// quit-and-reopen picks up the change; `relaunch()` is just the in-app shortcut.
    func applyBundleOverride() {
        let defaults = UserDefaults.standard
        if let localeCode {
            defaults.set([localeCode], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Launches a fresh instance, then terminates the current one so the new language loads.
    @MainActor
    static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}
