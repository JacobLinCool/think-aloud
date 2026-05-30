import AppKit
import SwiftUI

struct ModelPane: View {
    @Environment(AppContainer.self) private var container

    @State private var smokeReport: SmokeTestReport?
    @State private var smokeRunning: Bool = false
    @State private var smokeError: String?
    @State private var dictTestInput: String = ""

    var body: some View {
        Form {
            modelSection
            preEditSection
            postEditSection
            customDictionarySection
            memorySection
            smokeTestSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            Picker(String(localized: "Quality"), selection: Binding(
                get: { container.modelManager.profile },
                set: { container.modelManager.setProfile($0) }
            )) {
                ForEach(ModelProfile.allCases) { profile in
                    Text(profile.displayName).tag(profile)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("Status")
                Spacer()
                StatusBadge(tone: container.modelManager.runtimeStatus.badge,
                            text: container.modelManager.runtimeStatus.displayLabel)
            }
            if let progress = container.modelManager.runtimeStatus.downloadProgress {
                ProgressView(value: progress)
            } else if case .downloading = container.modelManager.runtimeStatus {
                ProgressView()
            } else if case .loading = container.modelManager.runtimeStatus {
                ProgressView()
            }

            HStack {
                Text("Identifier")
                Spacer()
                Text(container.modelManager.profile.shortName)
                    .foregroundStyle(.secondary)
                    .help(container.modelManager.modelID)
                RevealInFinderButton(url: container.modelManager.modelCacheURL)
            }

        } header: {
            Text("ASR Model")
        }
    }

    // MARK: - Auto Pre-Edit

    private var preEditSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { container.modelManager.preEdit.denoise },
                set: { container.modelManager.preEdit.denoise = $0 }
            )) {
                Text("Audio denoising")
                Text("Suppress background noise with DeepFilterNet before transcription. Downloads a small model on first use.")
            }

            if container.modelManager.preEdit.denoise {
                HStack {
                    Text("Denoiser")
                    Spacer()
                    StatusBadge(tone: container.modelManager.dfnStatus.badge,
                                text: container.modelManager.dfnStatus.displayLabel)
                }
                if container.modelManager.dfnStatus.isLoading {
                    ProgressView()
                }
                HStack {
                    Button(String(localized: "Load denoiser")) {
                        container.modelManager.preloadDFN()
                    }
                    .disabled(container.modelManager.dfnStatus.isLoading || container.modelManager.dfnStatus == .ready)

                    if container.modelManager.dfnStatus == .ready {
                        DestructiveButton(
                            "Unload denoiser",
                            confirmMessage: "Free the denoiser weights from memory? It will reload on next use.",
                            confirmLabel: "Unload"
                        ) {
                            container.modelManager.unloadDFNNow()
                        }
                    }
                }
            }
        } header: {
            Text("Auto Pre-Edit")
        } footer: {
            Text("Denoising runs at 48 kHz before the audio is downsampled for the ASR model. Best for noisy environments; may not help (or slightly hurt) clean recordings — use Benchmark to compare.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Auto Post-Edit

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
                Text("CJK–Latin spacing")
                Text("Insert a space between Chinese and adjacent English / numbers.")
            }
        } header: {
            Text("Auto Post-Edit")
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
            Text("Custom Dictionary")
        } footer: {
            Text("Replacements run last — after Chinese conversion and CJK–Latin spacing — and the longest matching term wins. Write terms the way the text looks after those steps. Longer, distinctive terms are safer; very short terms can fire inside unrelated words.")
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

    // MARK: - Memory

    private var memorySection: some View {
        Section {
            Picker(String(localized: "Auto-unload when idle"), selection: Binding(
                get: { container.modelManager.idleTimeout },
                set: { container.modelManager.idleTimeout = $0 }
            )) {
                ForEach(IdleTimeout.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Button(String(localized: "Load model")) {
                    container.modelManager.preloadNow()
                }
                .disabled(container.modelManager.runtimeStatus.isLoading || container.modelManager.runtimeStatus == .ready)

                DestructiveButton(
                    "Unload model",
                    confirmMessage: "Free model weights from memory? It will reload on next use.",
                    confirmLabel: "Unload"
                ) {
                    container.modelManager.unloadNow()
                }
                .disabled(container.modelManager.runtimeStatus != .ready)

                Spacer()

                Button {
                    container.modelManager.refreshStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Refresh status"))
            }
        } header: {
            Text("Memory")
        }
    }

    // MARK: - Smoke test

    private var smokeTestSection: some View {
        Section {
            HStack {
                Button(smokeRunning ? String(localized: "Running…") : String(localized: "Run smoke test")) {
                    runSmokeTest()
                }
                .disabled(smokeRunning)
                if smokeRunning {
                    ProgressView().controlSize(.small)
                }
            }
            if let report = smokeReport {
                SmokeReportView(report: report)
            }
            if let smokeError {
                Text(smokeError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Smoke test")
        } footer: {
            Text("Downloads three short clips from JacobLinCool/audio-testing and runs them through the current model. ~5 MB.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func runSmokeTest() {
        smokeRunning = true
        smokeError = nil
        let runtime = container.modelManager.runtime
        let postEdit = container.modelManager.postEdit
        let cacheDir = AppPaths.applicationSupportDirectory().appendingPathComponent("smoke-test-cache", isDirectory: true)
        Task { @MainActor in
            do {
                let runner = SmokeTestRunner(cacheDirectory: cacheDir)
                let report = try await runner.run(using: runtime, postEdit: postEdit)
                self.smokeReport = report
            } catch {
                self.smokeError = String(describing: error)
            }
            self.smokeRunning = false
        }
    }

}

private struct SmokeReportView: View {
    let report: SmokeTestReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model: \(report.modelID)")
                .font(.caption)
            Text("Output style: \(report.postEdit.summary)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Passed: \(report.passed) / \(report.total) · Average latency: \(report.averageLatencyMs) ms")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            ForEach(report.results) { result in
                resultRow(result)
            }
        }
    }

    @ViewBuilder
    private func resultRow(_ result: SmokeTestResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.passed ? .green : .orange)
                    .imageScale(.small)
                Text(result.sample.id)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(result.durationMs) ms")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let err = result.error {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(verbatim: "Raw: \(result.transcript)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                // Only show the edited line when post-processing actually changed something.
                if result.editedTranscript != result.transcript {
                    Text(verbatim: "Edited: \(result.editedTranscript)")
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
