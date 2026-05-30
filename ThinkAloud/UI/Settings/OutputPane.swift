import AppKit
import SwiftUI

/// Settings → Output: the everyday "make my transcription read the way I want" surface — audio
/// cleanup (denoise), text formatting (Chinese + spacing), and word replacements (custom
/// dictionary). Lifted verbatim from the old Model pane; labels are de-jargoned in a later phase.
struct OutputPane: View {
    @Environment(AppContainer.self) private var container

    @State private var dictTestInput: String = ""

    var body: some View {
        Form {
            preEditSection
            postEditSection
            customDictionarySection
        }
        .formStyle(.grouped)
    }

    // MARK: - Audio cleanup

    private var preEditSection: some View {
        Section {
            Picker(selection: Binding(
                get: { container.modelManager.preEdit.denoise },
                set: { container.modelManager.preEdit.denoise = $0 }
            )) {
                ForEach(DenoiseMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            } label: {
                Text("Clean up recordings")
                Text("Auto cleans only clips it detects as noisy; On always cleans (DeepFilterNet).")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Audio cleanup")
        } footer: {
            Text("Removes background noise before transcription. Auto only cleans clips it detects as noisy, and downloads a small model on first use. Manage the denoiser in Advanced; compare Off / Auto / On in Benchmark.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Text formatting

    private var postEditSection: some View {
        Section {
            Picker(String(localized: "Chinese output"), selection: Binding(
                get: { container.modelManager.postEdit.chinese },
                set: { container.modelManager.postEdit.chinese = $0 }
            )) {
                ForEach(ChinesePreference.allCases) { pref in
                    Text(pref.displayName).tag(pref)
                }
            }
            .pickerStyle(.menu)

            Toggle(isOn: Binding(
                get: { container.modelManager.postEdit.cjkLatinSpacing },
                set: { container.modelManager.postEdit.cjkLatinSpacing = $0 }
            )) {
                Text("Space between Chinese and English/numbers")
                Text("Insert a space between Chinese and adjacent English / numbers.")
            }
        } header: {
            Text("Text formatting")
        }
    }

    // MARK: - Custom dictionary

    private var dictionaryBinding: Binding<[DictionaryRule]> {
        Binding(
            get: { container.modelManager.postEdit.dictionary },
            set: { container.modelManager.postEdit.dictionary = $0 }
        )
    }

    private var customDictionarySection: some View {
        Section {
            ForEach(dictionaryBinding) { $rule in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $rule.enabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        TextField(String(localized: "term"), text: $rule.from)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                        TextField(String(localized: "replacement"), text: $rule.to)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            container.modelManager.postEdit.dictionary.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Remove term"))
                    }
                    if rule.enabled, isDuplicateRule(rule) {
                        dictWarning("Duplicate — only the first is used.")
                    } else if rule.enabled, CompiledDictionary.isShortTerm(rule) {
                        dictWarning("Short terms may replace text you didn't mean to.")
                    }
                }
            }

            Button {
                container.modelManager.postEdit.dictionary.append(DictionaryRule())
            } label: {
                Label(String(localized: "Add term"), systemImage: "plus")
            }

            // Live preview through the FULL pipeline (conversion + spacing + dictionary), so the
            // user authors against the text the dictionary actually sees (see the spacing note).
            VStack(alignment: .leading, spacing: 4) {
                TextField(String(localized: "Test — type to preview…"), text: $dictTestInput)
                    .textFieldStyle(.roundedBorder)
                if !dictTestInput.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary).imageScale(.small)
                        Text(TranscriptPostProcessor.apply(container.modelManager.postEdit, to: dictTestInput))
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }
        } header: {
            Text("Word replacements")
        } footer: {
            Text("Replacements run last — after Chinese conversion and spacing — and the longest matching term wins. Write terms the way the text looks after those steps. Longer, distinctive terms are safer; very short terms can fire inside unrelated words.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func dictWarning(_ key: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .imageScale(.small)
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// True when an earlier enabled, non-blank rule has the same ASCII-folded `from` (first-wins).
    private func isDuplicateRule(_ rule: DictionaryRule) -> Bool {
        guard rule.enabled, !rule.isBlank else { return false }
        let dict = container.modelManager.postEdit.dictionary
        guard let idx = dict.firstIndex(where: { $0.id == rule.id }) else { return false }
        let key = Array(rule.from).map(CompiledDictionary.key)
        for earlier in dict[..<idx] where earlier.enabled && !earlier.isBlank {
            if Array(earlier.from).map(CompiledDictionary.key) == key { return true }
        }
        return false
    }
}
