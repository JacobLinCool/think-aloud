import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol TextInserting: AnyObject {
    func insert(
        _ text: String,
        into focus: FocusContext?
    ) async -> TextInsertionManager.InsertionOutcome
}

@MainActor
final class TextInsertionManager: TextInserting {
    enum InsertionError: Error, LocalizedError {
        case accessibilityDenied
        case clipboardWriteFailed
        case eventPostFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return String(
                    localized: "Accessibility permission is required to paste text into other apps."
                )
            case .clipboardWriteFailed:
                return String(localized: "ThinkAloud couldn’t write the transcript to the clipboard.")
            case .eventPostFailed:
                return String(
                    localized: "ThinkAloud couldn’t paste into the previous app. The transcript remains on the clipboard."
                )
            }
        }
    }

    /// Result describing what happened during insertion.
    struct InsertionOutcome: Sendable {
        let inserted: Bool
        let copiedToClipboard: Bool
        let message: String
        let requiresAttention: Bool
    }

    static let restoreDelay: TimeInterval = 0.3

    /// Inserts the given text into the previously focused app via paste, falling back to clipboard-only if Accessibility is unavailable.
    func insert(_ text: String, into focus: FocusContext?) async -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        let previousItems = capturePasteboardItems(pasteboard)

        pasteboard.clearContents()
        let writeSuccess = pasteboard.setString(text, forType: .string)
        guard writeSuccess else {
            return InsertionOutcome(
                inserted: false,
                copiedToClipboard: false,
                message: String(localized: "ThinkAloud couldn’t copy the transcript. Keep this window open and try again."),
                requiresAttention: true
            )
        }
        let transcriptChangeCount = pasteboard.changeCount

        guard ensureAccessibility(prompt: true) else {
            return InsertionOutcome(
                inserted: false,
                copiedToClipboard: true,
                message: String(localized: "The transcript is on the clipboard. Paste it manually, or enable Accessibility in Settings."),
                requiresAttention: true
            )
        }

        if let pid = focus?.processID, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        let posted = postPasteEvent()
        if !posted {
            return InsertionOutcome(
                inserted: false,
                copiedToClipboard: true,
                message: String(localized: "ThinkAloud couldn’t paste automatically. The transcript is on the clipboard for manual pasting."),
                requiresAttention: true
            )
        }

        do {
            try await Task.sleep(for: .seconds(Self.restoreDelay))
        } catch {
            return InsertionOutcome(
                inserted: true,
                copiedToClipboard: true,
                message: String(localized: "The transcript was inserted, but ThinkAloud couldn’t restore the previous clipboard contents."),
                requiresAttention: true
            )
        }

        // Never overwrite content copied by the user or another app while the paste was settling.
        guard pasteboard.changeCount == transcriptChangeCount else {
            return InsertionOutcome(
                inserted: true,
                copiedToClipboard: false,
                message: String(localized: "Inserted. Newer clipboard contents were preserved."),
                requiresAttention: false
            )
        }
        guard restorePasteboardItems(previousItems, on: pasteboard) else {
            return InsertionOutcome(
                inserted: true,
                copiedToClipboard: false,
                message: String(localized: "The transcript was inserted, but ThinkAloud couldn’t restore the previous clipboard contents."),
                requiresAttention: true
            )
        }
        return InsertionOutcome(
            inserted: true,
            copiedToClipboard: false,
            message: String(localized: "Inserted."),
            requiresAttention: false
        )
    }

    /// Returns true if accessibility is granted. When prompt is true, surfaces the system prompt the first time it's checked.
    @discardableResult
    func ensureAccessibility(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt"
        let options: CFDictionary = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func postPasteEvent() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        let vKeyCode: CGKeyCode = 0x09 // "v"
        let mask: CGEventFlags = .maskCommand

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = mask
        keyUp.flags = mask
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func capturePasteboardItems(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        var snapshots: [NSPasteboardItem] = []
        for item in items {
            let snapshot = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    snapshot.setData(data, forType: type)
                }
            }
            snapshots.append(snapshot)
        }
        return snapshots
    }

    @discardableResult
    private func restorePasteboardItems(
        _ items: [NSPasteboardItem],
        on pasteboard: NSPasteboard
    ) -> Bool {
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        return pasteboard.writeObjects(items)
    }
}
