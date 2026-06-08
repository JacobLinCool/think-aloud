import AppKit
import SwiftUI

/// Settings → AI Refine: configure the LLM post-edit stage. A downloaded Qwen model (or Apple
/// Intelligence) rewrites the transcript after ASR; per-app overrides give different apps a different
/// style via a different system prompt over the same warm model.
struct RefinePane: View {
    @Environment(AppContainer.self) private var container

    @State private var editingAppBundleID: String?
    @State private var testInput = ""
    @State private var testOutput = ""
    @State private var testing = false

    private var llm: LLMManager { container.llmManager }

    var body: some View {
        Form {
            introSection
            modelSection
            defaultStyleSection
            perAppSection
            testSection
        }
        .formStyle(.grouped)
        .sheet(item: Binding(get: { editingAppBundleID.map { AppRef(bundleID: $0) } },
                             set: { editingAppBundleID = $0?.bundleID })) { ref in
            PerAppEditorSheet(bundleID: ref.bundleID, config: perAppBinding(ref.bundleID))
        }
    }

    // MARK: - Intro

    private var introSection: some View {
        Section {
            Toggle(isOn: defaultEnabledBinding) {
                Text("Refine transcripts with AI")
                Text("After transcription, an on-device language model rewrites the text — fixing fillers, grammar, and punctuation — before you insert it.")
            }
        } footer: {
            Text("This adds a brief \u{201C}Polishing…\u{201D} step after dictation. It needs a downloaded model (below) and falls back to the plain transcript if the model isn't ready or declines. Per-app overrides let work and chat apps get different styles.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Model

    private var modelSection: some View {
        Section {
            ForEach(LLMModelProfile.allCases) { profile in
                LLMModelRow(profile: profile, manager: llm)
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Download one model to use the Downloaded-model backend. Qwen3 are text models; Qwen3.5 are larger multimodal models run text-only. The selected model is shared across all apps.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Default style

    private var defaultStyleSection: some View {
        Section {
            backendPicker(for: defaultBackendBinding)
            promptEditor(for: defaultPromptBinding)
            temperatureSlider(for: defaultTemperatureBinding)
        } header: {
            Text("Default style")
        } footer: {
            Text("Applied to every app without its own override. The system prompt steers how the model rewrites your dictation.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Per-app overrides

    private var perAppSection: some View {
        Section {
            let bundleIDs = llm.config.perApp.keys.sorted()
            if bundleIDs.isEmpty {
                Text("No per-app overrides. Add an app to give it its own style.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(bundleIDs, id: \.self) { bundleID in
                HStack(spacing: 10) {
                    appIcon(bundleID)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(appDisplayName(bundleID)).lineLimit(1)
                        Text(llm.config.perApp[bundleID]?.enabled == true ? "On" : "Off")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") { editingAppBundleID = bundleID }
                        .controlSize(.small)
                    Button {
                        llm.config.perApp[bundleID] = nil
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Remove override"))
                }
            }
            Button {
                addApp()
            } label: {
                Label(String(localized: "Add app…"), systemImage: "plus")
            }
        } header: {
            Text("Per-app overrides")
        } footer: {
            Text("Pick an app and give it a tailored style — e.g. formal prose for work apps, casual for chat. Per-app prompts stay on this Mac and are never uploaded.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Test

    private var testSection: some View {
        Section {
            TextField(String(localized: "Type some text to preview the rewrite…"), text: $testInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            HStack {
                Button {
                    runTest()
                } label: {
                    if testing { ProgressView().controlSize(.small) } else { Text("Test refine") }
                }
                .disabled(testInput.isEmpty || testing || !llm.isDownloaded(llm.selectedModel) && llm.config.defaultProfile.backend == .mlx)
                Spacer()
            }
            if !testOutput.isEmpty {
                Text(testOutput)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        } header: {
            Text("Preview")
        } footer: {
            Text("Runs the default style on whatever you type, using the same model and prompt your dictations will use. First run loads the model, which can take a few seconds.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Shared controls

    @ViewBuilder
    private func backendPicker(for binding: Binding<LLMBackend>) -> some View {
        Picker(String(localized: "Engine"), selection: binding) {
            Text(LLMBackend.mlx.displayName).tag(LLMBackend.mlx)
            if AppleFoundationAvailability.isAvailable {
                Text(LLMBackend.appleFoundation.displayName).tag(LLMBackend.appleFoundation)
            }
        }
        .pickerStyle(.menu)
        if binding.wrappedValue == .appleFoundation, !AppleFoundationAvailability.isAvailable,
           let reason = AppleFoundationAvailability.unavailableReason {
            Text(reason).font(.caption).foregroundStyle(.orange)
        } else if !AppleFoundationAvailability.isAvailable {
            Text("Apple Intelligence isn't available on this Mac; using a downloaded model.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func promptEditor(for binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("System prompt").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: binding)
                .font(.callout)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func temperatureSlider(for binding: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Creativity")
                Spacer()
                Text(String(format: "%.1f", binding.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: binding, in: 0...1, step: 0.1)
            Text("Lower stays faithful to what you said; higher rewrites more freely.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Bindings

    private var defaultEnabledBinding: Binding<Bool> {
        Binding(get: { llm.config.defaultProfile.enabled }, set: { llm.config.defaultProfile.enabled = $0 })
    }
    private var defaultBackendBinding: Binding<LLMBackend> {
        Binding(get: { llm.config.defaultProfile.backend }, set: { llm.config.defaultProfile.backend = $0 })
    }
    private var defaultPromptBinding: Binding<String> {
        Binding(get: { llm.config.defaultProfile.systemPrompt }, set: { llm.config.defaultProfile.systemPrompt = $0 })
    }
    private var defaultTemperatureBinding: Binding<Double> {
        Binding(get: { llm.config.defaultProfile.temperature }, set: { llm.config.defaultProfile.temperature = $0 })
    }
    private func perAppBinding(_ bundleID: String) -> Binding<LLMProfileConfig> {
        Binding(
            get: { container.llmManager.config.perApp[bundleID] ?? LLMProfileConfig(enabled: true) },
            set: { container.llmManager.config.perApp[bundleID] = $0 }
        )
    }

    // MARK: - Apps

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Add")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        if llm.config.perApp[bundleID] == nil {
            // Seed from the default style so the user tweaks rather than starts blank.
            var seed = llm.config.defaultProfile
            seed.enabled = true
            llm.config.perApp[bundleID] = seed
        }
        editingAppBundleID = bundleID
    }

    private func appDisplayName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    @ViewBuilder
    private func appIcon(_ bundleID: String) -> some View {
        if let icon = AppIcons.icon(forBundleID: bundleID) {
            Image(nsImage: icon).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed").foregroundStyle(.tertiary).frame(width: 18, height: 18)
        }
    }

    // MARK: - Test run

    private func runTest() {
        let input = testInput
        let profile = llm.config.defaultProfile
        testing = true
        testOutput = ""
        Task { @MainActor in
            defer { testing = false }
            var out = ""
            do {
                for try await chunk in llm.refine(input, using: profile.enabled ? profile : LLMProfileConfig(enabled: true, backend: profile.backend, systemPrompt: profile.systemPrompt, temperature: profile.temperature)) {
                    out += chunk
                    testOutput = out
                }
            } catch {
                testOutput = String(localized: "Failed: \(error.localizedDescription)")
            }
            if out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                testOutput = String(localized: "(no output — the model declined or isn't ready)")
            }
        }
    }
}

/// Identifiable wrapper so a bundle id can drive a `.sheet(item:)`.
private struct AppRef: Identifiable { let bundleID: String; var id: String { bundleID } }

// MARK: - Per-app editor sheet

private struct PerAppEditorSheet: View {
    let bundleID: String
    @Binding var config: LLMProfileConfig
    @Environment(\.dismiss) private var dismiss
    @Environment(AppContainer.self) private var container

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Style for \(displayName)").font(.headline)
            Toggle(String(localized: "Refine in this app"), isOn: $config.enabled)
            Picker(String(localized: "Engine"), selection: $config.backend) {
                Text(LLMBackend.mlx.displayName).tag(LLMBackend.mlx)
                if AppleFoundationAvailability.isAvailable {
                    Text(LLMBackend.appleFoundation.displayName).tag(LLMBackend.appleFoundation)
                }
            }
            .pickerStyle(.menu)
            Text("System prompt").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $config.systemPrompt)
                .font(.callout).frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button(String(localized: "Done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var displayName: String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

// MARK: - Model row

private struct LLMModelRow: View {
    let profile: LLMModelProfile
    @Bindable var manager: LLMManager

    var body: some View {
        HStack(spacing: 10) {
            Button {
                manager.setModel(profile)
            } label: {
                Image(systemName: manager.selectedModel == profile ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(manager.selectedModel == profile ? Color.accentColor : .secondary)
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Use this model"))

            VStack(alignment: .leading, spacing: 1) {
                Text(profile.displayName).fontWeight(manager.selectedModel == profile ? .semibold : .regular)
                Text(statusText).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let status = manager.profileDownloadStatus[profile], status.isLoading {
            VStack(alignment: .trailing, spacing: 2) {
                if let p = status.downloadProgress {
                    ProgressView(value: p).frame(width: 90)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        } else if manager.isDownloaded(profile) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                DestructiveButton("Remove", confirmMessage: "Remove \(profile.displayName) (\(profile.estimatedDownloadSize))?", confirmLabel: "Remove") {
                    try? manager.removeModel(profile)
                }
                .controlSize(.small)
            }
        } else {
            Button {
                Task { try? await manager.downloadModel(profile) }
            } label: {
                Label(profile.estimatedDownloadSize, systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
        }
    }

    private var statusText: String {
        if manager.isDownloaded(profile) { return profile.tagline }
        return "\(profile.estimatedDownloadSize) · \(profile.tagline)"
    }
}
