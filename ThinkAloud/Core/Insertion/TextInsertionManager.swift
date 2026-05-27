import AppKit
import ApplicationServices
import Foundation

@MainActor
final class TextInsertionManager {
    enum InsertionError: Error, LocalizedError {
        case accessibilityDenied
        case clipboardWriteFailed
        case eventPostFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied: return "Accessibility permission is required to paste text into other apps."
            case .clipboardWriteFailed: return "Failed to write to the clipboard."
            case .eventPostFailed: return "Failed to post the paste keyboard event."
            }
        }
    }

    /// Result describing what happened during insertion.
    struct InsertionOutcome: Sendable {
        let inserted: Bool
        let copiedToClipboard: Bool
        let message: String
    }

    static let restoreDelay: TimeInterval = 0.3

    /// Inserts the given text into the previously focused app via paste, falling back to clipboard-only if Accessibility is unavailable.
    func insert(_ text: String, into focus: FocusContext?) async -> InsertionOutcome {
        let pasteboard = NSPasteboard.general
        let previousItems = capturePasteboardItems(pasteboard)

        pasteboard.clearContents()
        let writeSuccess = pasteboard.setString(text, forType: .string)
        guard writeSuccess else {
            return InsertionOutcome(inserted: false, copiedToClipboard: false, message: String(localized: "Failed to write to clipboard."))
        }

        guard ensureAccessibility(prompt: true) else {
            return InsertionOutcome(inserted: false, copiedToClipboard: true, message: String(localized: "Accessibility permission missing. Text copied to clipboard — please paste manually."))
        }

        if let pid = focus?.processID, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [])
            try? await Task.sleep(nanoseconds: 80_000_000)
        }

        let posted = postPasteEvent()
        if !posted {
            return InsertionOutcome(inserted: false, copiedToClipboard: true, message: String(localized: "Failed to send paste event. Text copied — please paste manually."))
        }

        try? await Task.sleep(nanoseconds: UInt64(Self.restoreDelay * 1_000_000_000))
        restorePasteboardItems(previousItems, on: pasteboard)
        return InsertionOutcome(inserted: true, copiedToClipboard: true, message: String(localized: "Inserted."))
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

    private func restorePasteboardItems(_ items: [NSPasteboardItem], on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
