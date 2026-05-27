# ThinkAloud

Local-first voice input for macOS. Press a hotkey anywhere, dictate, get the text pasted into the focused app — and optionally save the recording + transcript as a personal dataset.

Built around [Qwen3-ASR](https://huggingface.co/mlx-community?search_models=Qwen3-ASR) running on-device via [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift). No cloud, no telemetry.

## Features

- **One hotkey, whole flow.** Default `⌥Space` starts recording → press again to stop & transcribe → press again to insert & save. The three actions are also rebindable separately.
- **Streaming transcription** with editable preview before inserting.
- **Chinese output preference** — keep model output as-is, prefer Traditional (正體), or prefer Simplified (簡體). Conversion runs locally via ICU.
- **Dataset browser** — play recordings, scrub the timeline, edit transcripts, bulk delete.
- **Built-in benchmark** — re-run any saved model against your dataset, see CER + exact-match rate + per-character git-style diff. Multiple runs kept for cross-model comparison. JSON export.
- **Push to Hugging Face Hub** — full LFS support, repo card auto-generated, token stored in macOS Keychain.
- **Idle auto-unload** of model weights to free memory between sessions.

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon (M-series)
- ~600 MB – 4 GB free disk per model variant
- Internet on first run (model download) and for HF push

## Quick start

1. Launch ThinkAloud — a microphone icon appears in the menu bar.
2. Grant **Microphone** and **Accessibility** the first time the system asks (or via Settings → Permissions).
3. Click into any text field in any app.
4. Press `⌥Space` to start recording.
5. Press `⌥Space` to stop and transcribe (streamed live into the popup).
6. Press `⌥Space` to insert into the focused app and save to your dataset.

(Or just press once and rely on the same key dispatching the right action per phase.)

## Settings

| Pane | What it controls |
| --- | --- |
| **Hotkeys** | Per-action keybindings (start / stop / insert + save). All default to `⌥Space`. |
| **Permissions** | Microphone + Accessibility status. One-click "Open System Settings". |
| **Model** | Quality preset (Fast / Balanced / Accurate Qwen3-ASR variants), Chinese output preference, idle auto-unload timeout, smoke test. |
| **Dataset** | Storage stats, open data folder, export JSONL, clear all. Opens the dataset browser. |
| **Advanced** | Per-model download/remove. Hugging Face token. |

## Dataset browser

Open from menu bar **Browse Dataset…** (`⌘D`) or Settings → Dataset.

- **Records** — saved dictations. Play, scrub, edit the transcript (raw stays immutable, edited overwrites). Multi-select + `⌘⌫` for bulk delete. Push the whole dataset to HF Hub from the toolbar.
- **Benchmark** — pick a model + Chinese preference, run the full pipeline (audio decode → model → post-process) against every record. Reports overall CER, exact-match rate, average latency; per-record diffs show what the model omitted (green underline) vs hallucinated (red strikethrough). Multiple runs are kept in-session for comparison and can be exported as JSON.

## Privacy

- All audio is processed on-device. Nothing is sent to a server unless you explicitly press **Push** in the dataset browser.
- The Hugging Face token is stored in macOS Keychain — never on disk in plain text, never in UserDefaults.
- Recordings are only saved to your dataset when you choose **Insert & save**. Plain Insert discards the audio.
- The dataset (SQLite + WAV files) lives at `~/Library/Application Support/ThinkAloud/`.

## Build from source

```bash
# Install build tooling
brew install xcodegen

# Generate the Xcode project from project.yml
xcodegen generate

# Build
xcodebuild -project ThinkAloud.xcodeproj -scheme ThinkAloud -configuration Debug build

# Run tests (37 unit tests; one optional live ASR test gated by env)
xcodebuild -project ThinkAloud.xcodeproj -scheme ThinkAloud -configuration Debug test
```

To open in Xcode: `open ThinkAloud.xcodeproj`.

The project signs with Developer ID Application (so TCC permissions persist across builds). To build locally, edit `project.yml` and replace `DEVELOPMENT_TEAM` with your own team ID, then regenerate.

## Tech stack

- SwiftUI + AppKit, Swift 6, macOS 15+
- [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift) — Qwen3-ASR runtime
- [mlx-swift](https://github.com/ml-explore/mlx-swift) — Apple's MLX
- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite layer
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — global hotkeys
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — project file generation

## Status

MVP. Working end-to-end on macOS 15.x / Apple Silicon. Tested with Qwen3-ASR 0.6B-4bit, 1.7B-4bit, and 1.7B-8bit variants.
