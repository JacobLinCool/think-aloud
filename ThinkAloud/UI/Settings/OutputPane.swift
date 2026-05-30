import AppKit
import SwiftUI

/// Settings → Output: the everyday "make my transcription read the way I want" surface — audio
/// cleanup (denoise), text formatting (Chinese + spacing), and word replacements (custom
/// dictionary). Lifted verbatim from the old Model pane; labels are de-jargoned in a later phase.
struct OutputPane: View {
    @Environment(AppContainer.self) private var container

    @State private var previewInput: String = ""

    var body: some View {
        Form {
            preEditSection
            postEditSection
            customDictionarySection
            previewSection
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

            DenoiseTesterView()
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
        } header: {
            Text("Word replacements")
        } footer: {
            Text("Replacements run last — after Chinese conversion and spacing — and the longest matching term wins. Write terms the way the text looks after those steps; use the Preview below to check. Longer, distinctive terms are safer; very short terms can fire inside unrelated words.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Preview (whole text pipeline)

    private struct FormattingStage: Identifiable {
        let id = UUID()
        let label: LocalizedStringKey
        let text: String
        var isResult = false
    }

    private var previewSection: some View {
        Section {
            TextField(String(localized: "Type to preview the formatting…"), text: $previewInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)

            if !previewInput.isEmpty {
                let cfg = container.modelManager.postEdit
                let stages = pipelineStages(cfg, input: previewInput)
                stageRow(FormattingStage(label: "Input", text: previewInput, isResult: stages.isEmpty))
                ForEach(stages) { stageRow($0) }
                if stages.isEmpty {
                    Text("No formatting steps are active — the output matches your input.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Preview")
        } footer: {
            Text("Runs the whole text pipeline — Chinese conversion, then spacing, then your word replacements — on whatever you type, showing what each active step changes. The last line is the final inserted text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func stageRow(_ stage: FormattingStage) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(stage.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(stage.text.isEmpty ? " " : stage.text)
                .font(stage.isResult ? .callout.weight(.medium) : .callout)
                .foregroundStyle(stage.isResult ? .primary : .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The cumulative output after each ACTIVE step, in pipeline order. Built from partial configs
    /// so each row reflects exactly what that step (and the ones before it) produced — the last row
    /// is the final text. Empty when no step is active.
    private func pipelineStages(_ cfg: PostEditConfig, input: String) -> [FormattingStage] {
        var stages: [FormattingStage] = []
        if cfg.chinese != .model {
            let t = TranscriptPostProcessor.apply(PostEditConfig(chinese: cfg.chinese), to: input)
            stages.append(FormattingStage(label: "Chinese conversion", text: t))
        }
        if cfg.cjkLatinSpacing {
            let t = TranscriptPostProcessor.apply(PostEditConfig(chinese: cfg.chinese, cjkLatinSpacing: true), to: input)
            stages.append(FormattingStage(label: "Spacing", text: t))
        }
        if cfg.activeRuleCount > 0 {
            let t = TranscriptPostProcessor.apply(cfg, to: input)
            stages.append(FormattingStage(label: "Word replacements", text: t))
        }
        if !stages.isEmpty {
            stages[stages.count - 1].isResult = true
        }
        return stages
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
