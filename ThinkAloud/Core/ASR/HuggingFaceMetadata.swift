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

    /// Sum the byte sizes of all files in the repository's `main` revision.
    /// Returns `nil` on network or parse errors so callers can fall back to
    /// progress-without-total UI.
    static func totalRepoSize(modelID: String) async -> Int64? {
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
                .filter { $0.type == "file" }
                .map(\.effectiveSize)
                .reduce(0, +)
            return total > 0 ? total : nil
        } catch {
            return nil
        }
    }
}
