import HuggingFace
import XCTest
@testable import ThinkAloud

final class HubDownloadClientTests: XCTestCase {
    /// Regression: model downloads must not pick up a Hugging Face token from the ambient
    /// environment. A stale `hf_oauth_*` token in `~/.cache/huggingface/token` used to 401 every
    /// download, which surfaced as "check your connection and available disk space".
    func testDownloadClientIgnoresAmbientToken() async throws {
        setenv("HF_TOKEN", "hf_ambient_token_that_must_not_be_used", 1)
        defer { unsetenv("HF_TOKEN") }

        let cache = HubCache(cacheDirectory: FileManager.default.temporaryDirectory)
        let client = HubDownloadClient.make(cache: cache)
        let token = await client.bearerToken
        XCTAssertNil(token)
    }
}
