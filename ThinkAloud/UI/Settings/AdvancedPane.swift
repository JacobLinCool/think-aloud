import AppKit
import SwiftUI

struct AdvancedPane: View {
    @Environment(AppContainer.self) private var container

    @State private var hfTokenDraft: String = ""
    @State private var hfStatus: HFStatus = .idle

    enum HFStatus: Equatable {
        case idle
        case testing
        case verified(String)
        case failed(String)
    }

    var body: some View {
        Form {
            huggingFaceSection
        }
        .formStyle(.grouped)
        .onAppear {
            // Don't pre-fill the actual token — show empty field so a fresh save replaces it.
            hfTokenDraft = ""
            if let v = container.hfTokenStore.verifiedUsername {
                hfStatus = .verified(v)
            }
        }
    }

    // MARK: - HF section

    private var huggingFaceSection: some View {
        Section {
            HStack {
                Text("Token")
                Spacer()
                if container.hfTokenStore.hasToken {
                    StatusBadge(tone: .ok, text: String(localized: "Saved"))
                } else {
                    StatusBadge(tone: .neutral, text: String(localized: "Not set"))
                }
            }
            SecureField(String(localized: "hf_… (paste here, then Save)"), text: $hfTokenDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(String(localized: "Save token")) {
                    saveToken()
                }
                .disabled(hfTokenDraft.isEmpty)
                Button(String(localized: "Test connection")) {
                    testConnection()
                }
                .disabled(!container.hfTokenStore.hasToken)
                Spacer()
                if container.hfTokenStore.hasToken {
                    Button(role: .destructive) {
                        clearToken()
                    } label: {
                        Text(String(localized: "Clear"))
                    }
                    .controlSize(.small)
                }
            }
            switch hfStatus {
            case .idle:
                EmptyView()
            case .testing:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Testing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .verified(let user):
                Text("Signed in as **\(user)**")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let msg):
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        } header: {
            Text("Hugging Face")
        } footer: {
            Text("Used to push the dataset from the browser window. Token is stored in macOS Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveToken() {
        do {
            try container.hfTokenStore.save(token: hfTokenDraft)
            hfTokenDraft = ""
            hfStatus = .idle
        } catch {
            hfStatus = .failed(String(localized: "Keychain save failed: \(error.localizedDescription)"))
        }
    }

    private func clearToken() {
        do {
            try container.hfTokenStore.clear()
            hfTokenDraft = ""
            hfStatus = .idle
        } catch {
            hfStatus = .failed(String(localized: "Keychain clear failed: \(error.localizedDescription)"))
        }
    }

    private func testConnection() {
        guard let token = container.hfTokenStore.token else { return }
        hfStatus = .testing
        Task { @MainActor in
            let client = HFHubClient(token: token)
            do {
                let me = try await client.whoami()
                container.hfTokenStore.verifiedUsername = me.name
                hfStatus = .verified(me.name)
            } catch {
                hfStatus = .failed(String(localized: "Connection failed: \(error.localizedDescription)"))
            }
        }
    }
}
