import AppKit
import SwiftUI

struct BenchmarkView: View {
    @Bindable var controller: BenchmarkController

    @State private var exportToastVisible: Bool = false
    @State private var confirmModelDownload: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                setupSection
                Divider()
                if let err = controller.errorMessage {
                    errorBanner(err)
                }
                if let err = controller.exportErrorMessage {
                    errorBanner(err)
                }
                if controller.isRunning {
                    progressSection
                } else if !controller.history.isEmpty {
                    reportArea
                } else {
                    placeholderSection
                }
            }
            .frame(maxWidth: 880, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: controller.lastExportPath) { _, newValue in
            guard newValue != nil else { return }
            exportToastVisible = true
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await MainActor.run { exportToastVisible = false }
            }
        }
        .confirmationDialog(
            String(localized: "Download model and run benchmark?"),
            isPresented: $confirmModelDownload,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Download \(controller.selectedProfile.estimatedDownloadSize) and Run")) {
                controller.run()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("The selected \(controller.selectedProfile.displayName) model is not downloaded. Benchmark will download approximately \(controller.selectedProfile.estimatedDownloadSize), then load it into memory before processing records.")
        }
    }

    // MARK: - Setup

    @ViewBuilder
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Setup")
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 300), spacing: 24),
                    GridItem(.flexible(minimum: 260))
                ],
                alignment: .leading,
                spacing: 10
            ) {
                modelPicker
                chineseOutputPicker
                denoisePicker
                spacingToggle
            }
            HStack(spacing: 12) {
                if !controller.selectedModelIsDownloaded && !controller.isRunning {
                    Label(
                        String(localized: "Not downloaded · \(controller.selectedProfile.estimatedDownloadSize)"),
                        systemImage: "arrow.down.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                runControls
            }
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        Picker(String(localized: "Model"), selection: $controller.selectedProfile) {
            ForEach(ModelProfile.allCases) { profile in
                Text(profile.displayName).tag(profile)
            }
        }
        .pickerStyle(.menu)
        .disabled(controller.isRunning)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var chineseOutputPicker: some View {
        Picker(String(localized: "Chinese output"), selection: $controller.selectedPostEdit.chinese) {
            ForEach(ChinesePreference.allCases) { preference in
                Text(preference.displayName).tag(preference)
            }
        }
        .pickerStyle(.menu)
        .disabled(controller.isRunning)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var denoisePicker: some View {
        Picker(String(localized: "Denoise"), selection: $controller.selectedPreEdit.denoise) {
            ForEach(DenoiseMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .disabled(controller.isRunning)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var spacingToggle: some View {
        Toggle(
            String(localized: "Space between Chinese and English/numbers"),
            isOn: $controller.selectedPostEdit.cjkLatinSpacing
        )
        .toggleStyle(.checkbox)
        .disabled(controller.isRunning)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var runControls: some View {
        HStack(spacing: 8) {
            Button {
                if controller.selectedModelIsDownloaded {
                    controller.run()
                } else {
                    confirmModelDownload = true
                }
            } label: {
                Label(String(localized: "Run benchmark"), systemImage: "gauge.with.dots.needle.50percent")
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isRunning)
            if controller.isRunning {
                Button(role: .destructive) {
                    controller.cancel()
                } label: {
                    if controller.cancellationRequested {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("Canceling…")
                        }
                    } else {
                        Label(String(localized: "Cancel"), systemImage: "stop.fill")
                    }
                }
                .disabled(controller.cancellationRequested)
            }
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(stageTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            if controller.stage == .running {
                ProgressView(value: controller.progressFraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(stageTitle)
                    .accessibilityValue("\(controller.progressCompleted) of \(controller.progressTotal)")
                HStack {
                    Text("\(controller.progressCompleted.formatted()) / \(controller.progressTotal.formatted())")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    if let id = controller.currentRecordID {
                        Text("Current: \(id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(stageTitle)
            }
            if let configuration = controller.activeConfiguration {
                Text("\(configuration.profile.displayName) · \(configuration.preEdit.summary) · \(configuration.postEdit.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var stageTitle: String {
        switch controller.stage {
        case .idle: return String(localized: "Preparing benchmark")
        case .loadingRecords: return String(localized: "Loading records")
        case .downloadingModel(let estimatedSize):
            return String(localized: "Downloading model (\(estimatedSize))")
        case .loadingModel: return String(localized: "Loading model into memory")
        case .preparingDenoiser: return String(localized: "Preparing denoiser")
        case .running: return String(localized: "Running benchmark")
        }
    }

    // MARK: - Report

    @ViewBuilder
    private var reportArea: some View {
        VStack(alignment: .leading, spacing: 14) {
            historyBar
            if let report = controller.displayedReport {
                reportSection(report)
            }
        }
    }

    @ViewBuilder
    private var historyBar: some View {
        if controller.history.count > 1 {
            HStack(spacing: 6) {
                Text("Run")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(String(localized: "Run"), selection: Binding(
                    get: { controller.displayedRunID ?? controller.history.first?.runID ?? "" },
                    set: { controller.displayedRunID = $0 }
                )) {
                    ForEach(controller.history, id: \.runID) { r in
                        Text(historyLabel(r)).tag(r.runID)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel(String(localized: "Run"))
                .frame(maxWidth: 400)
                Spacer()
            }
        }
    }

    private func historyLabel(_ report: BenchmarkReport) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timeText = iso.date(from: report.runAt).map { f.string(from: $0) } ?? report.runAt
        let modelShort = report.modelID.components(separatedBy: "/").last ?? report.modelID
        return "\(timeText) · \(modelShort) · \(report.preEdit.summary) · \(report.postEdit.summary)"
    }

    @ViewBuilder
    private func reportSection(_ report: BenchmarkReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeader("Results")
                if exportToastVisible {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill").imageScale(.small)
                        Text("Exported")
                    }
                    .font(.caption)
                    .foregroundStyle(.green)
                    .transition(.opacity)
                }
                Spacer()
                Button {
                    exportReport(report)
                } label: {
                    Label(String(localized: "Export JSON"), systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: exportToastVisible)

            summaryGrid(report)

            metricsToggleBar

            cerLegend

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(report.results) { r in
                    resultRow(r)
                }
            }
        }
    }

    @ViewBuilder
    private func summaryGrid(_ report: BenchmarkReport) -> some View {
        let useNorm = controller.useNormalizedMetrics
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                summaryCell(label: String(localized: "Model"), value: report.modelID)
                summaryCell(label: String(localized: "Output style"), value: report.postEdit.summary)
            }
            GridRow {
                summaryCell(label: String(localized: "Denoise"), value: report.preEdit.summary)
            }
            GridRow {
                summaryCell(label: String(localized: "Total"), value: report.total.formatted())
                summaryCell(
                    label: String(localized: "Exact match"),
                    value: "\(report.exactMatchCount(useNormalized: useNorm).formatted()) (\(report.exactMatchRate(useNormalized: useNorm).formatted(.percent.precision(.fractionLength(1)))))"
                )
            }
            GridRow {
                summaryCell(
                    label: String(localized: "Avg CER"),
                    value: report.averageCER(useNormalized: useNorm).formatted(.number.precision(.fractionLength(3))),
                    tooltip: String(localized: "Character Error Rate — 0 means perfect, lower is better.")
                )
                summaryCell(
                    label: String(localized: "Avg WER"),
                    value: report.averageWER(useNormalized: useNorm).formatted(.number.precision(.fractionLength(3))),
                    tooltip: String(localized: "Word Error Rate — CJK ideographs count as words; 0 means perfect, lower is better.")
                )
            }
            GridRow {
                summaryCell(label: String(localized: "Avg latency"), value: durationLabel(milliseconds: report.averageLatencyMs))
                summaryCell(
                    label: String(localized: "Avg RTF"),
                    value: report.averageRTF.map { "\($0.formatted(.number.precision(.fractionLength(2))))×" } ?? "—",
                    tooltip: String(localized: "Real-Time Factor — processing time ÷ audio length. Below 1.0× is faster than real time.")
                )
            }
            if report.failed > 0 {
                GridRow {
                    summaryCell(label: String(localized: "Failed"), value: report.failed.formatted(), tone: .red)
                }
            }
        }
    }

    @ViewBuilder
    private var metricsToggleBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $controller.useNormalizedMetrics) {
                Text("Normalize (lowercase + strip punctuation + full-width → half-width)")
                    .font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Spacer()
        }
    }

    @ViewBuilder
    private func summaryCell(label: String, value: String, tone: Color = .primary, tooltip: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let tooltip {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help(tooltip)
                }
            }
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(tone)
        }
    }

    @ViewBuilder
    private var cerLegend: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 14) {
                legendDot(.green, symbol: "checkmark.circle.fill", label: String(localized: "Exact"))
                legendDot(.yellow, symbol: "circle.lefthalf.filled", label: String(localized: "CER < 0.1"))
                legendDot(.orange, symbol: "circle.dotted", label: String(localized: "CER 0.1–0.3"))
                legendDot(.red, symbol: "xmark.circle.fill", label: String(localized: "CER > 0.3"))
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text("Error")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 14) {
                // Char-diff colors mirror git semantics relative to the ground truth.
                HStack(spacing: 4) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.green)
                    Text("Missing (model omitted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.red)
                    Text("Extra (model hallucinated)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func legendDot(_ color: Color, symbol: String, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .imageScale(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func resultRow(_ r: BenchmarkResult) -> some View {
        let useNorm = controller.useNormalizedMetrics
        let cerValue = r.cer(useNormalized: useNorm)
        let isExact = r.exactMatch(useNormalized: useNorm)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: rowIcon(r, isExact: isExact))
                    .foregroundStyle(rowColor(r, cer: cerValue, isExact: isExact))
                    .imageScale(.small)
                    .accessibilityLabel(rowStatus(r, cer: cerValue, isExact: isExact))
                Text(r.id)
                    .font(.caption.weight(.medium))
                Spacer()
                if r.error == nil {
                    Text("CER \(cerValue.formatted(.number.precision(.fractionLength(2))))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(durationLabel(milliseconds: r.durationMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            if let err = r.error {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if isExact {
                Text(verbatim: r.predictedEdited)
                    .font(.caption2)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            } else {
                HStack(alignment: .top, spacing: 6) {
                    Text("Diff")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                    diffText(reference: r.groundTruth, hypothesis: r.predictedEdited)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(diffAccessibilityLabel(reference: r.groundTruth, hypothesis: r.predictedEdited))
            }
        }
        .padding(.vertical, 4)
    }

    /// Renders a git-style colored diff: from the model's prediction toward the ground truth.
    ///   - equal chars: primary
    ///   - `.delete` (in truth, missing from prediction → prediction is **missing this**):
    ///     green underline. Read as "needs to be added".
    ///   - `.insert` (in prediction, not in truth → prediction **wrongly said this**):
    ///     red strikethrough. Read as "needs to be removed".
    private func diffText(reference: String, hypothesis: String) -> Text {
        let segments = TextDiff.diff(reference: reference, hypothesis: hypothesis)
        var out = Text(verbatim: "")
        for seg in segments {
            switch seg.op {
            case .equal:
                out = out + Text(seg.text).foregroundColor(.primary)
            case .delete:
                // Model omitted this — show in green as "should have been here".
                out = out + Text(seg.text)
                    .foregroundColor(.green)
                    .underline()
            case .insert:
                // Model hallucinated this — show in red as "shouldn't be here".
                out = out + Text(seg.text)
                    .foregroundColor(.red)
                    .strikethrough()
            }
        }
        return out.font(.caption2)
    }

    private func rowIcon(_ r: BenchmarkResult, isExact: Bool) -> String {
        if r.error != nil { return "exclamationmark.triangle.fill" }
        if isExact { return "checkmark.circle.fill" }
        return "circle.fill"
    }

    private func rowColor(_ r: BenchmarkResult, cer: Double, isExact: Bool) -> Color {
        if r.error != nil { return .red }
        if isExact { return .green }
        if cer < 0.1 { return .yellow }
        if cer < 0.3 { return .orange }
        return .red
    }

    private func rowStatus(_ r: BenchmarkResult, cer: Double, isExact: Bool) -> String {
        if r.error != nil { return String(localized: "Error") }
        if isExact { return String(localized: "Exact match") }
        if cer < 0.1 { return String(localized: "Character error rate below 0.1") }
        if cer < 0.3 { return String(localized: "Character error rate between 0.1 and 0.3") }
        return String(localized: "Character error rate above 0.3")
    }

    private func diffAccessibilityLabel(reference: String, hypothesis: String) -> String {
        let segments = TextDiff.diff(reference: reference, hypothesis: hypothesis)
        return segments.map { segment in
            switch segment.op {
            case .equal: return segment.text
            case .delete: return String(localized: "Missing: \(segment.text)")
            case .insert: return String(localized: "Extra: \(segment.text)")
            }
        }.joined(separator: ", ")
    }

    private func durationLabel(milliseconds: Int) -> String {
        Measurement(value: Double(milliseconds), unit: UnitDuration.milliseconds)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    // MARK: - Placeholder

    @ViewBuilder
    private var placeholderSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Run the full pipeline against every record")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Compares the model's post-processed output with the saved edited transcript. Reports CER, exact-match rate, and average latency.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    // MARK: - Export

    private func exportReport(_ report: BenchmarkReport) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "benchmark-\(report.modelID.replacingOccurrences(of: "/", with: "_")).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try controller.exportJSON(to: url)
            } catch {
                controller.recordExportFailure(error)
            }
        }
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(String(localized: "Benchmark error: \(message)"))
    }
}
