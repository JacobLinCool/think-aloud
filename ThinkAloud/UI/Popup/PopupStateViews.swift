import SwiftUI

struct IdlePopupView: View {
    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Preparing…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RecordingPopupView: View {
    @Bindable var viewModel: PopupViewModel
    let coordinator: PopupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeat(.continuous))
                Text(formattedElapsed)
                    .font(.title2.monospacedDigit())
                Spacer()
                Text("Recording")
                    .foregroundStyle(.red)
                    .font(.subheadline)
            }
            LevelMeterView(rms: viewModel.levelRMS, peak: viewModel.levelPeak)
            Spacer()
            HStack {
                Button("Cancel") { coordinator.cancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Stop & Transcribe") { coordinator.stopAndTranscribe() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var formattedElapsed: String {
        let total = Int(viewModel.elapsedSeconds)
        let minutes = total / 60
        let seconds = total % 60
        let millis = Int((viewModel.elapsedSeconds - Double(total)) * 10)
        return String(format: "%02d:%02d.%01d", minutes, seconds, millis)
    }
}

struct LevelMeterView: View {
    let rms: Float
    let peak: Float

    var body: some View {
        GeometryReader { geo in
            let rmsWidth = CGFloat(min(max(rms * 3, 0), 1)) * geo.size.width
            let peakWidth = CGFloat(min(max(peak * 2, 0), 1)) * geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.35)).frame(width: peakWidth)
                RoundedRectangle(cornerRadius: 4).fill(Color.accentColor).frame(width: rmsWidth)
            }
        }
        .frame(height: 14)
    }
}

struct TranscribingPopupView: View {
    let coordinator: PopupCoordinator
    @Bindable var modelManager: ModelManager

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            // `waitingForModel` is computed from live runtimeStatus so the message updates if
            // the model finishes loading mid-wait.
            if !modelManager.runtimeStatus.isReady {
                Text("Model is loading — your recording is ready. Transcribing as soon as the model is ready.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("Transcribing…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Cancel") { coordinator.cancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReviewPopupView: View {
    @Bindable var viewModel: PopupViewModel
    let coordinator: PopupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Lock the editor while tokens are still streaming in — otherwise user edits get
            // clobbered by the next token write to editedTranscript.
            TextEditor(text: $viewModel.editedTranscript)
                .font(.body)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .disabled(viewModel.isStreaming)
                .opacity(viewModel.isStreaming ? 0.85 : 1.0)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if viewModel.isStreaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Transcribing… (streaming)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Raw: \(viewModel.rawTranscript)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text("Model: \(viewModel.asrModelID) · \(viewModel.transcribeDurationMs) ms")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }

            if !viewModel.lastInsertionMessage.isEmpty {
                Text(viewModel.lastInsertionMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { coordinator.cancel() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Insert") { coordinator.insertOnly() }
                    .keyboardShortcut("i", modifiers: [.command])
                    .disabled(viewModel.isStreaming || viewModel.editedTranscript.isEmpty)
                Button("Insert & Save") { coordinator.insertAndSave() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isStreaming || viewModel.editedTranscript.isEmpty)
            }
        }
    }
}

struct ErrorPopupView: View {
    let message: String
    let coordinator: PopupCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Open Settings") { coordinator.openSettings() }
                Spacer()
                Button("Close") { coordinator.cancel() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}
