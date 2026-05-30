import AppKit
import SwiftUI

struct ModelPane: View {
    @Environment(AppContainer.self) private var container

    @State private var smokeReport: SmokeTestReport?
    @State private var smokeRunning: Bool = false
    @State private var smokeError: String?

    var body: some View {
        Form {
            modelSection
            memorySection
            smokeTestSection
        }
        .formStyle(.grouped)
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
