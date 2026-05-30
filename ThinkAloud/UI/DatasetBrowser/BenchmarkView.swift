import AppKit
import SwiftUI

struct BenchmarkView: View {
    @Bindable var controller: BenchmarkController

    @State private var exportToastVisible: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                setupSection
                Divider()
                if controller.isRunning {
                    progressSection
                } else if !controller.history.isEmpty {
                    reportArea
                } else if let err = controller.errorMessage {
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.red)
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
    }

    // MARK: - Setup

    @ViewBuilder
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Setup")
            HStack(spacing: 12) {
                LabeledContent(String(localized: "Model")) {
                    Picker("", selection: $controller.selectedProfile) {
                        ForEach(ModelProfile.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                LabeledContent(String(localized: "Chinese output")) {
                    Picker("", selection: $controller.selectedPostEdit.chinese) {
                        ForEach(ChinesePreference.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Toggle(String(localized: "Space between Chinese and English/numbers"), isOn: $controller.selectedPostEdit.cjkLatinSpacing)
                    .toggleStyle(.checkbox)
                LabeledContent(String(localized: "Denoise")) {
                    Picker("", selection: $controller.selectedPreEdit.denoise) {
                        ForEach(DenoiseMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
                Spacer()
                Button {
                    controller.run()
                } label: {
                    Label(String(localized: "Run benchmark"), systemImage: "gauge.with.dots.needle.50percent")
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isRunning)
                if controller.isRunning {
                    Button(role: .destructive) {
                        controller.cancel()
                    } label: {
                        Label(String(localized: "Cancel"), systemImage: "stop.fill")
                    }
                }
            }
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Running")
            ProgressView(value: controller.progressFraction)
                .progressViewStyle(.linear)
            HStack {
                Text("\(controller.progressCompleted) / \(controller.progressTotal)")
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
                Picker("", selection: Binding(
                    get: { controller.displayedRunAt ?? controller.history.first?.runAt ?? "" },
                    set: { controller.displayedRunAt = $0 }
                )) {
                    ForEach(controller.history, id: \.runAt) { r in
                        Text(historyLabel(r)).tag(r.runAt)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 400)
                Spacer()
            }
        }
    }

    private func historyLabel(_ report: BenchmarkReport) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let timeText = iso.date(from: report.runAt).map { f.string(from: $0) } ?? report.runAt
        let modelShort = report.modelID.components(separatedBy: "/").last ?? report.modelID
        return "\(timeText) · \(modelShort)"
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
            .animation(.easeOut(duration: 0.2), value: exportToastVisible)

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
                summaryCell(label: String(localized: "Total"), value: "\(report.total)")
                summaryCell(
                    label: String(localized: "Exact match"),
                    value: "\(report.exactMatchCount(useNormalized: useNorm)) (\(String(format: "%.1f%%", report.exactMatchRate(useNormalized: useNorm) * 100)))"
                )
            }
            GridRow {
                summaryCell(
                    label: String(localized: "Avg CER"),
                    value: String(format: "%.3f", report.averageCER(useNormalized: useNorm)),
                    tooltip: String(localized: "Character Error Rate — 0 means perfect, lower is better.")
                )
                summaryCell(
                    label: String(localized: "Avg WER"),
                    value: String(format: "%.3f", report.averageWER(useNormalized: useNorm)),
                    tooltip: String(localized: "Word Error Rate — CJK ideographs count as words; 0 means perfect, lower is better.")
                )
            }
            GridRow {
                summaryCell(label: String(localized: "Avg latency"), value: "\(report.averageLatencyMs) ms")
                summaryCell(
                    label: String(localized: "Avg RTF"),
                    value: report.averageRTF.map { String(format: "%.2f×", $0) } ?? "—",
                    tooltip: String(localized: "Real-Time Factor — processing time ÷ audio length. Below 1.0× is faster than real time.")
                )
            }
            if report.failed > 0 {
                GridRow {
                    summaryCell(label: String(localized: "Failed"), value: "\(report.failed)", tone: .red)
                }
            }
        }
    }

    @ViewBuilder
    private var metricsToggleBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $controller.useNormalizedMetrics) {
                Text("Normalize (lowercase + strip punctuation + 全→半形)")
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
                legendDot(.green, label: String(localized: "Exact"))
                legendDot(.yellow, label: String(localized: "CER < 0.1"))
                legendDot(.orange, label: String(localized: "0.1–0.3"))
                legendDot(.red, label: String(localized: "> 0.3"))
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
                    Text("綠")
                        .font(.caption2)
                        .foregroundColor(.green)
                        .underline()
                    Text("Missing (model omitted)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text("紅")
                        .font(.caption2)
                        .foregroundColor(.red)
                        .strikethrough()
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
    private func legendDot(_ color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 8, height: 8)
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
                Text(r.id)
                    .font(.caption.weight(.medium))
                Spacer()
                if r.error == nil {
                    Text("CER \(String(format: "%.2f", cerValue))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("\(r.durationMs) ms")
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
                }
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
        var out = Text("")
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

    // MARK: - Placeholder

    @ViewBuilder
    private var placeholderSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
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
                NSLog("ThinkAloud: benchmark export failed: \(error)")
            }
        }
    }
}
