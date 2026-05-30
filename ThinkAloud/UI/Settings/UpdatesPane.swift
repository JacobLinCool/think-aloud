import SwiftUI

struct UpdatesPane: View {
    @Environment(AppContainer.self) private var container

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        @Bindable var updater = container.updater

        Form {
            Section {
                InfoRow("Current version", value: versionString)

                HStack {
                    Button(String(localized: "Check for Updates…")) {
                        container.updater.checkForUpdates()
                    }
                    .disabled(!container.updater.canCheckForUpdates)
                    Spacer()
                }
            } header: {
                Text("Updates")
            }

            Section {
                Picker(String(localized: "Channel"), selection: $updater.channel) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
                Toggle(String(localized: "Automatically check for updates"),
                       isOn: $updater.automaticallyChecksForUpdates)
                Toggle(String(localized: "Automatically download and install updates"),
                       isOn: $updater.automaticallyDownloadsUpdates)
                    // "Download & install" only makes sense once automatic checks are on.
                    .disabled(!updater.automaticallyChecksForUpdates)
            } footer: {
                Text("Updates are downloaded from GitHub Releases and verified with a cryptographic signature before installing. The Dev channel tracks the latest main build and may be less stable; switching back to Stable takes effect once Stable's build number catches up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
