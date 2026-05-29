import SwiftUI

struct ModelStep: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                OnboardingHeader(
                    title: "Choose a speech model",
                    subtitle: "Pick the model that fits your Mac. It downloads once and runs on-device. You can switch anytime in Settings."
                )

                VStack(spacing: 8) {
                    ForEach(ModelProfile.allCases) { profile in
                        modelRow(profile)
                    }
                }

                statusArea
            }
            .padding(32)
        }
    }

    private var manager: ModelManager { container.modelManager }

    // MARK: - Rows

    private func modelRow(_ profile: ModelProfile) -> some View {
        let isSelected = manager.profile == profile
        let downloaded = manager.isDownloaded(profile)
        return Button {
            // Avoid switching mid-download: the status poll tracks one runtime at a time.
            guard !manager.runtimeStatus.isLoading else { return }
            manager.setProfile(profile)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.displayName).font(.headline)
                        if downloaded {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .imageScale(.small)
                                .help(String(localized: "Already downloaded"))
                        }
                    }
                    Text(profile.tagline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(downloaded ? String(localized: "Downloaded") : profile.estimatedDownloadSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(manager.runtimeStatus.isLoading)
    }

    // MARK: - Status / download

    @ViewBuilder
    private var statusArea: some View {
        let status = manager.runtimeStatus
        let downloaded = manager.isDownloaded(manager.profile)

        VStack(alignment: .leading, spacing: 10) {
            if status.isLoading {
                HStack {
                    StatusBadge(tone: status.badge, text: status.displayLabel)
                    Spacer()
                }
                if let progress = status.downloadProgress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                }
            } else if status.isReady || downloaded {
                Label(String(localized: "Ready to use"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button {
                    manager.preloadNow()
                } label: {
                    Label(String(localized: "Download & load model"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)

                Text("This downloads the selected model now so your first transcription is instant.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = manager.lastError, case .failed = status {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if !(status.isReady || downloaded) {
                Button(String(localized: "Download later")) {
                    container.onboardingState.next()
                }
                .buttonStyle(.link)
                .padding(.top, 2)
            }
        }
        .padding(.top, 4)
    }
}
