import AppKit
import SwiftUI

/// Settings → Advanced: power and troubleshooting tools a normal user never needs — memory tuning
/// and diagnostics. The model-file management moved to Model; the Hugging Face token moved to
/// Dataset (its only job is pushing the dataset).
struct AdvancedPane: View {
    @Environment(AppContainer.self) private var container

    @State private var smokeReport: SmokeTestReport?
    @State private var smokeRunning: Bool = false
    @State private var smokeCancellationRequested = false
    @State private var smokeError: String?
    @State private var smokeTask: Task<Void, Never>?
    @State private var diagnosticsExpanded = false

    var body: some View {
        Form {
            if let error = container.modelManager.settingsError {
                SettingsPersistenceErrorSection(error: error)
            }
            memorySection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .onDisappear {
            smokeTask?.cancel()
        }
    }

    // MARK: - Memory & performance

    private var memorySection: some View {
        Section {
            HStack {
                Text("Speech model")
                Spacer()
                StatusBadge(
                    tone: container.modelManager.runtimeStatus.badge,
                    text: container.modelManager.runtimeStatus.displayLabel
                )
            }

            Picker(String(localized: "Auto-unload when idle"), selection: Binding(
                get: { container.modelManager.idleTimeout },
                set: { container.modelManager.idleTimeout = $0 }
            )) {
                ForEach(IdleTimeout.allCases) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel(String(localized: "Auto-unload when idle"))

            HStack {
                if container.modelManager.preloadIsRunning {
                    Button(
                        container.modelManager.preloadCancellationRequested
                            ? String(localized: "Canceling Model Load…")
                            : String(localized: "Cancel Model Load")
                    ) {
                        container.modelManager.cancelPreload()
                    }
                    .disabled(container.modelManager.preloadCancellationRequested)
                } else {
                    Button(String(localized: "Load model")) {
                        container.modelManager.preloadNow()
                    }
                    .disabled(
                        container.modelManager.runtimeStatus.isLoading
                            || container.modelManager.runtimeStatus == .ready
                    )
                }

                // Reversible — a plain button, no scary confirmation dialog.
                Button(String(localized: "Unload model")) {
                    container.modelManager.unloadNow()
                }
                .disabled(container.modelManager.runtimeStatus != .ready)
            }

            if case .failed = container.modelManager.runtimeStatus {
                VStack(alignment: .leading, spacing: 6) {
                    if let detail = container.modelManager.lastError {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    Button(String(localized: "Retry Loading Speech Model")) {
                        container.modelManager.preloadNow()
                    }
                    .controlSize(.small)
                    Button(String(localized: "Open Model Settings…")) {
                        container.openSettings(to: .model)
                    }
                    .controlSize(.small)
                }
            }

            if container.modelManager.preEdit.denoise != .off {
                HStack {
                    Text("Denoiser")
                    Spacer()
                    StatusBadge(tone: container.modelManager.dfnStatus.badge,
                                text: container.modelManager.dfnStatus.displayLabel)
                }
                HStack {
                    Button(String(localized: "Load denoiser")) {
                        container.modelManager.preloadDFN()
                    }
                    .disabled(container.modelManager.dfnStatus.isLoading || container.modelManager.dfnStatus == .ready)

                    Button(String(localized: "Unload denoiser")) {
                        container.modelManager.unloadDFNNow()
                    }
                    .disabled(container.modelManager.dfnStatus != .ready)
                }
            }
        } header: {
            HStack {
                Text("Memory & performance")
                Spacer()
                RefreshButton { container.modelManager.refreshStatus() }
            }
        } footer: {
            Text("Load keeps the model in memory for instant transcription; Unload frees it. Auto-unload releases the weights after the chosen idle time and reloads on next use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $diagnosticsExpanded) {
                HStack {
                    if smokeRunning {
                        Button(
                            smokeCancellationRequested
                                ? String(localized: "Canceling Test…")
                                : String(localized: "Cancel Test")
                        ) {
                            smokeCancellationRequested = true
                            smokeTask?.cancel()
                        }
                        .disabled(smokeCancellationRequested)
                    } else {
                        Button(String(localized: "Run test")) {
                            runSmokeTest()
                        }
                    }
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
            } label: {
                Text("Test the model")
            }
            .accessibilityAction { diagnosticsExpanded.toggle() }

            Button(String(localized: "Run Setup Assistant…")) {
                container.openOnboarding()
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("“Test the model” downloads three short clips from JacobLinCool/audio-testing (~5 MB) and runs them through the current model. Cancel takes effect after the model finishes the sample it is currently transcribing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func runSmokeTest() {
        smokeRunning = true
        smokeCancellationRequested = false
        smokeError = nil
        let runtime = container.modelManager.runtime
        let postEdit = container.modelManager.postEdit
        let cacheDir = container.applicationSupportDirectory.appendingPathComponent("smoke-test-cache", isDirectory: true)
        smokeTask = Task { @MainActor in
            defer {
                self.smokeRunning = false
                self.smokeCancellationRequested = false
                self.smokeTask = nil
            }
            do {
                let runner = try SmokeTestRunner(cacheDirectory: cacheDir)
                let report = try await runner.run(using: runtime, postEdit: postEdit)
                try Task.checkCancellation()
                self.smokeReport = report
            } catch is CancellationError {
                self.smokeError = nil
            } catch {
                NSLog("ThinkAloud: model test failed: \(error)")
                if let smokeTestError = error as? SmokeTestError {
                    self.smokeError = smokeTestError.localizedDescription
                } else {
                    self.smokeError = String(
                        localized: "The model test couldn’t finish. Check the model, your connection, and available storage, then try again."
                    )
                }
            }
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
            Text("Passed: \(report.passed) / \(report.total) · Average latency: \(formattedDuration(report.averageLatencyMs))")
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
                Text(formattedDuration(result.durationMs))
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

    private func formattedDuration(_ milliseconds: Int) -> String {
        Measurement(value: Double(milliseconds), unit: UnitDuration.milliseconds)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(0))
                )
            )
    }
}
