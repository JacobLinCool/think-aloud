import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// All three action hotkeys default to the same combo (Option+Space). The coordinator's
    /// phase guards make them mutually exclusive — only the one matching the current phase
    /// performs work; the others early-return. Users can rebind any of them independently.
    static let startRecording = Self("startRecording", default: .init(.space, modifiers: [.option]))
    static let stopAndTranscribe = Self("stopAndTranscribe", default: .init(.space, modifiers: [.option]))
    static let insertAndSave = Self("insertAndSave", default: .init(.space, modifiers: [.option]))
}
