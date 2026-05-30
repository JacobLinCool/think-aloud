import AppKit
import SwiftUI

/// Settings → Advanced: power and troubleshooting tools a normal user never needs — memory tuning
/// and diagnostics. The model-file management moved to Model; the Hugging Face token moved to
/// Dataset (its only job is pushing the dataset).
struct AdvancedPane: View {
    @Environment(AppContainer.self) private var container

    @State private var smokeReport: SmokeTestReport?
    @State private var smokeRunning: Bool = false
    @State private var smokeError: String?

    var body: some View {
        Form {
            memorySection
            diagnosticsSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Memory & performance

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

                // Reversible — a plain button, no scary confirmation dialog.
                Button(String(localized: "Unload model")) {
                    container.modelManager.unloadNow()
                }
                .disabled(container.modelManager.runtimeStatus != .ready)
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
            DisclosureGroup {
                HStack {
                    Button(smokeRunning ? String(localized: "Running…") : String(localized: "Run test")) {
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
            } label: {
                Text("Test the model")
            }

            Button(String(localized: "Run Setup Assistant again")) {
                container.openOnboarding()
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("“Test the model” downloads three short clips from JacobLinCool/audio-testing (~5 MB) and runs them through the current model to verify it works.")
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
