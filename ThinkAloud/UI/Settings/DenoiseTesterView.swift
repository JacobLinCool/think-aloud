import SwiftUI

/// "Test my environment" control embedded in the Audio cleanup section: records a short sample,
/// shows whether Auto denoise would fire (and why), and lets the user A/B the original vs. cleaned
/// audio. Collapsed by default so it doesn't crowd the simple Off/Auto/On picker.
struct DenoiseTesterView: View {
    @Environment(AppContainer.self) private var container
    @State private var tester = DenoiseTester()

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(.top, 4)
        } label: {
            Text("Test my environment")
        }
        .onDisappear { tester.reset() }
    }

    @ViewBuilder
    private var content: some View {
        switch container.permissions.microphoneStatus {
        case .granted:
            phaseContent
        case .notDetermined:
            Text("Microphone access is needed to record a test sample.")
                .font(.caption).foregroundStyle(.secondary)
            Button(String(localized: "Request access")) {
                Task { await container.permissions.requestMicrophone() }
            }
        case .denied, .unknown:
            Text("Microphone access is off. Enable it to record a test sample.")
                .font(.caption).foregroundStyle(.secondary)
            Button(String(localized: "Open System Settings")) {
                container.permissions.openMicrophoneSettings()
            }
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch tester.phase {
        case .idle:
            Text("Records a few seconds so you can see whether Auto would clean it — speak a sentence as you normally would, then Stop.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                tester.startRecording { try await container.modelManager.denoise($0) }
            } label: {
                Label(String(localized: "Record a sample"), systemImage: "record.circle")
            }

        case .recording:
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("Recording… \(Int(tester.elapsed))s")
                    .monospacedDigit()
                Spacer()
                Button(String(localized: "Stop")) {
                    tester.stopAndProcess()
                }
                .buttonStyle(.borderedProminent)
            }

        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Analyzing & cleaning… (the first run downloads the denoiser)")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .ready:
            if let decision = tester.decision {
                resultView(decision)
            }

        case .failed(let msg):
            Text(msg)
                .font(.caption).foregroundStyle(.red)
            Button(String(localized: "Try again")) { tester.reset() }
        }
    }

    @ViewBuilder
    private func resultView(_ decision: DenoiseDecision) -> some View {
        // Headline framed by what Auto WOULD do for this clip.
        HStack(spacing: 6) {
            Image(systemName: decision.shouldDenoise ? "sparkles" : "checkmark.circle")
                .foregroundStyle(decision.shouldDenoise ? Color.accentColor : .green)
            Text(decision.shouldDenoise
                 ? "Auto would clean this clip"
                 : "Auto would leave this clip as-is")
                .font(.callout.weight(.medium))
        }
        Text(verdictDetail(decision))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        // Contextualize against the CURRENT mode (the decision above is for Auto).
        switch container.modelManager.preEdit.denoise {
        case .on:
            Text("Your current mode is On, so every recording is cleaned regardless.")
                .font(.caption2).foregroundStyle(.secondary)
        case .off:
            Text("Your current mode is Off, so no recording is cleaned. Switch to Auto or On to use this.")
                .font(.caption2).foregroundStyle(.secondary)
        case .auto:
            EmptyView()
        }

        // A/B playback.
        HStack(spacing: 12) {
            playButton(title: String(localized: "Original"), url: tester.originalURL, id: "denoise-original")
            playButton(title: String(localized: "Cleaned"), url: tester.denoisedURL, id: "denoise-cleaned")
            Spacer()
            Button(String(localized: "Record again")) { tester.reset() }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func playButton(title: String, url: URL?, id: String) -> some View {
        let isPlaying = tester.player.playingID == id && tester.player.isPlaying
        Button {
            if let url { tester.player.toggle(url: url, id: id) }
        } label: {
            Label(title, systemImage: isPlaying ? "pause.fill" : "play.fill")
        }
        .controlSize(.small)
        .disabled(url == nil)
    }

    /// Plain-language explanation of the decision + the numbers behind it.
    private func verdictDetail(_ d: DenoiseDecision) -> String {
        let snr = String(format: "%.0f", d.snrDB)
        let threshold = String(format: "%.0f", DenoiseHeuristic.snrNoisyDB)
        switch d.reason {
        case .noisy:
            return String(localized: "Steady background noise detected (signal-to-noise ≈ \(snr) dB, below the \(threshold) dB threshold).")
        case .clean:
            return String(localized: "Quiet enough — clear gaps between speech (signal-to-noise ≈ \(snr) dB, at/above the \(threshold) dB threshold).")
        case .noSpeech:
            return String(localized: "No clear speech detected (too little dynamic range). Try again and speak a full sentence.")
        case .clipping:
            return String(localized: "The audio is clipping (too loud) — cleaning is forced. Move back from the mic or lower the input level.")
        case .tooShort:
            return String(localized: "The clip was too short to judge. Record a couple of seconds.")
        }
    }
}
