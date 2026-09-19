import Foundation
import HuggingFace

/// The `HubClient` used to fetch *model weights* (ASR + refine LLM).
///
/// swift-huggingface's `HubClient(cache:)` convenience resolves its bearer token from the
/// ambient environment — `HF_TOKEN`, `HUGGING_FACE_HUB_TOKEN`, `$HF_TOKEN_PATH`, `$HF_HOME/token`,
/// `~/.cache/huggingface/token`, `~/.huggingface/token` — i.e. from whatever the Hugging Face CLI
/// or some other tool happened to leave on this Mac. Every repo ThinkAloud downloads is public, so
/// that token buys us nothing, and a *stale* one costs us everything: `hf auth login` writes an
/// `hf_oauth_*` JWT that expires, after which every download 401s. mlx-audio sees the empty result,
/// throws `incompleteDownload`, wipes the model directory, and the user gets
/// "Couldn't download … Check your connection and available disk space" — which sends them
/// debugging a network that was never broken.
///
/// So model downloads always go out anonymously. The personal access token in Keychain
/// (`HFKeychain`) stays on the dataset-push path, where the user actually entered it.
enum HubDownloadClient {
    static func make(cache: HubCache) -> HubClient {
        // Passing an explicit (nil) bearerToken selects the `.none` token provider; the
        // `HubClient(cache:)` overload would select `.environment` instead.
        HubClient(host: HubClient.defaultHost, bearerToken: nil, cache: cache)
    }
}
