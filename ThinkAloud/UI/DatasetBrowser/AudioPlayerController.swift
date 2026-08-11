import AVFoundation
import Foundation
import Observation

/// Single-instance audio playback for the dataset browser. Only one record plays at a time;
/// playing a different record stops whatever was previously playing.
@MainActor
@Observable
final class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case error(String)
    }

    private(set) var playingID: String?
    private(set) var isPlaying: Bool = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    private(set) var loadState: LoadState = .idle

    /// While true, the polling task does not overwrite `currentTime`. The detail view sets
    /// this during a Slider drag so the scrub position doesn't fight with playback position.
    var isScrubbing: Bool = false {
        didSet {
            if !isScrubbing, let player {
                currentTime = player.currentTime
            }
        }
    }

    private var player: AVAudioPlayer?
    private var pollingTask: Task<Void, Never>?

    func beginLoading(id: String) {
        stop()
        playingID = id
        loadState = .loading
    }

    func reportLoadError(_ error: Error, id: String) {
        NSLog("ThinkAloud: audio lookup failed for record \(id): \(error)")
        stop()
        playingID = id
        loadState = .error(
            String(
                localized: "The recording’s audio file is unavailable. Refresh the dataset after restoring the file."
            )
        )
    }

    /// Loads the file without starting playback. Lets the detail view show a scrubbable Slider
    /// with the correct duration before the user clicks ▶.
    func prepare(url: URL, id: String) {
        if playingID == id, loadState == .ready { return }
        stop()
        loadState = .loading
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            self.player = p
            self.playingID = id
            self.duration = p.duration
            self.currentTime = 0
            self.isPlaying = false
            self.loadState = .ready
        } catch {
            NSLog("ThinkAloud: audio player preparation failed for record \(id): \(error)")
            loadState = .error(
                String(
                    localized: "The recording couldn’t be loaded. Verify the audio file, then try again."
                )
            )
        }
    }

    /// Toggles play/pause for the given URL+id. Switching to a new id stops the old one.
    func toggle(url: URL, id: String) {
        if playingID == id, let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
                stopPolling()
            } else {
                if player.play() {
                    isPlaying = true
                    startPolling()
                } else {
                    isPlaying = false
                    loadState = .error(String(localized: "Playback could not start."))
                }
            }
            return
        }
        // Different (or first) clip — fresh player.
        stop()
        loadState = .loading
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            guard p.play() else {
                throw NSError(
                    domain: "ThinkAloud.AudioPlayer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: String(localized: "Playback could not start.")]
                )
            }
            self.player = p
            self.playingID = id
            self.duration = p.duration
            self.currentTime = 0
            self.isPlaying = true
            self.loadState = .ready
            startPolling()
        } catch {
            NSLog("ThinkAloud: audio playback failed for record \(id): \(error)")
            stop()
            playingID = id
            loadState = .error(
                String(
                    localized: "The recording couldn’t be played. Verify the audio file, then try again."
                )
            )
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = max(0, min(time, player.duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        player?.stop()
        player = nil
        playingID = nil
        isPlaying = false
        duration = 0
        currentTime = 0
        isScrubbing = false
        loadState = .idle
    }

    private func startPolling() {
        stopPolling()
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                if !self.isScrubbing {
                    self.currentTime = player.currentTime
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.stopPolling()
        }
    }
}
