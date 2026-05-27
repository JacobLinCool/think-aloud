import KeyboardShortcuts

@MainActor
final class HotkeyManager {
    struct Handlers {
        let startRecording: () -> Void
        let stopAndTranscribe: () -> Void
        let insertAndSave: () -> Void
    }

    private var handlers: Handlers?

    func bind(handlers: Handlers) {
        self.handlers = handlers
        KeyboardShortcuts.onKeyDown(for: .startRecording) { [weak self] in
            self?.handlers?.startRecording()
        }
        KeyboardShortcuts.onKeyDown(for: .stopAndTranscribe) { [weak self] in
            self?.handlers?.stopAndTranscribe()
        }
        KeyboardShortcuts.onKeyDown(for: .insertAndSave) { [weak self] in
            self?.handlers?.insertAndSave()
        }
    }

    func unbind() {
        KeyboardShortcuts.removeAllHandlers()
        handlers = nil
    }
}
