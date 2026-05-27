import AVFoundation
import Foundation
import Observation

/// Single-instance audio playback for the dataset browser. Only one record plays at a time;
/// playing a different record stops whatever was previously playing.
@MainActor
@Observable
final class AudioPlayerController: NSObject, AVAudioPlayerDelegate {
    private(set) var playingID: String?
    private(set) var isPlaying: Bool = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0

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

    /// Loads the file without starting playback. Lets the detail view show a scrubbable Slider
    /// with the correct duration before the user clicks ▶.
    func prepare(url: URL, id: String) {
        if playingID == id { return }
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            self.player = p
            self.playingID = id
            self.duration = p.duration
            self.currentTime = 0
            self.isPlaying = false
        } catch {
            NSLog("ThinkAloud: AudioPlayer prepare failed for \(url.lastPathComponent): \(error)")
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
                player.play()
                isPlaying = true
                startPolling()
            }
            return
        }
        // Different (or first) clip — fresh player.
        stop()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            p.play()
            self.player = p
            self.playingID = id
            self.duration = p.duration
            self.currentTime = 0
            self.isPlaying = true
            startPolling()
        } catch {
            NSLog("ThinkAloud: AudioPlayer failed for \(url.lastPathComponent): \(error)")
            stop()
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
