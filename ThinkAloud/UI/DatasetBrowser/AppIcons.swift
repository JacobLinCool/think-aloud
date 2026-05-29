import AppKit

/// Looks up an app's Finder icon by bundle identifier. Used to decorate dataset rows with the
/// source app's icon. Returns `nil` if the bundle ID is unknown or the app isn't installed.
@MainActor
enum AppIcons {
    // Maps to NSImage? (not NSImage) so unresolvable bundle IDs are cached as a definitive nil.
    // Otherwise rows whose source app isn't installed would re-hit Launch Services
    // (NSWorkspace.urlForApplication) synchronously on the main thread on every body eval — a
    // per-frame cost while scrolling the dataset list.
    private static var cache: [String: NSImage?] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        // `cache[bundleID]` is NSImage??; a present key (even with a nil value) binds here.
        if let cached = cache[bundleID] { return cached }
        let resolved: NSImage?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            resolved = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            resolved = nil
        }
        // updateValue (not subscript = nil, which would delete the key) stores the nil verdict.
        cache.updateValue(resolved, forKey: bundleID)
        return resolved
    }
}
