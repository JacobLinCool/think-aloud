import AppKit

/// Looks up an app's Finder icon by bundle identifier. Used to decorate dataset rows with the
/// source app's icon. Returns `nil` if the bundle ID is unknown or the app isn't installed.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = image
        return image
    }
}
