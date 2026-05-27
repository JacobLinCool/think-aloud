import AppKit
import SwiftUI

/// Coloured status badge for read-only state rows in Settings (permissions, model status, etc.).
struct StatusBadge: View {
    enum Tone {
        case ok       // granted / ready
        case warn     // not requested / loading
        case error    // denied / failed
        case neutral  // unknown / not loaded
    }

    let tone: Tone
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(color)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private var icon: String {
        switch tone {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .neutral: return "circle"
        }
    }

    private var color: Color {
        switch tone {
        case .ok: return .green
        case .warn: return .orange
        case .error: return .red
        case .neutral: return .secondary
        }
    }
}

/// Small icon button that reveals a file or folder in Finder.
struct RevealInFinderButton: View {
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Image(systemName: "arrow.up.right.square")
                .imageScale(.medium)
        }
        .buttonStyle(.borderless)
        .help(String(localized: "Reveal in Finder"))
    }
}

/// Destructive button that opens a confirmation dialog before running the action.
/// Used for irrecoverable operations like clearing the dataset or wiping the model cache.
struct DestructiveButton: View {
    private let titleKey: LocalizedStringKey
    private let messageKey: LocalizedStringKey
    private let confirmKey: LocalizedStringKey
    private let action: () -> Void

    @State private var showConfirm = false

    init(
        _ titleKey: LocalizedStringKey,
        confirmMessage messageKey: LocalizedStringKey,
        confirmLabel confirmKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) {
        self.titleKey = titleKey
        self.messageKey = messageKey
        self.confirmKey = confirmKey
        self.action = action
    }

    var body: some View {
        Button(titleKey, role: .destructive) {
            showConfirm = true
        }
        .confirmationDialog(messageKey, isPresented: $showConfirm, titleVisibility: .visible) {
            Button(confirmKey, role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// Read-only key/value row inside a settings Form. Keeps label primary, value secondary, right-aligned.
struct InfoRow<Trailing: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            trailing()
        }
    }
}

extension InfoRow where Trailing == Text {
    init(_ label: LocalizedStringKey, value: String) {
        self.label = label
        self.trailing = { Text(value).foregroundStyle(.secondary) }
    }
}
