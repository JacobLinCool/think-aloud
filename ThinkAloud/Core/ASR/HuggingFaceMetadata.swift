import Foundation

/// Minimal Hugging Face Hub API client just to fetch repo file sizes so we can
/// compute download progress percentages locally.
enum HuggingFaceMetadata {
    private struct TreeEntry: Decodable {
        let path: String
        let type: String
        let size: Int64?
        let lfs: LFS?

        struct LFS: Decodable {
            let size: Int64?
        }

        var effectiveSize: Int64 {
            lfs?.size ?? size ?? 0
        }
    }

    /// Sum only the files the downstream downloader will request from the repository's `main`
    /// revision. Counting the whole repository is incorrect for repos that also publish optimizer
    /// checkpoints or alternate framework weights.
    /// Returns `nil` on network or parse errors so callers can fall back to
    /// progress-without-total UI.
    static func downloadSize(modelID: String, matchingPatterns: [String]) async -> Int64? {
        let urlString = "https://huggingface.co/api/models/\(modelID)/tree/main?recursive=true"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
            let total = entries
                .filter {
                    $0.type == "file"
                        && matches(path: $0.path, matchingPatterns: matchingPatterns)
                }
                .map(\.effectiveSize)
                .reduce(0, +)
            return total > 0 ? total : nil
        } catch {
            return nil
        }
    }

    /// Implements the filename patterns used by the two upstream downloaders. Their manifests use
    /// either extension globs (`*.json`) or exact filenames (`merges.txt`).
    static func matches(path: String, matchingPatterns: [String]) -> Bool {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        return matchingPatterns.contains { pattern in
            if pattern.hasPrefix("*.") {
                return filename.lowercased().hasSuffix(String(pattern.dropFirst()).lowercased())
            }
            return filename == pattern
        }
    }
}
