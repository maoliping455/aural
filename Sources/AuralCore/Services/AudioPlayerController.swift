import AVFoundation
import Foundation

public final class AudioPlayerController {
    private var player: AVAudioPlayer?
    public private(set) var playbackRate: Float = 1.0

    public init() {}

    public var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    public var currentTime: TimeInterval {
        player?.currentTime ?? 0
    }

    public var duration: TimeInterval {
        player?.duration ?? 0
    }

    public func load(url: URL) throws {
        stop()
        let audioPlayer = try AVAudioPlayer(contentsOf: url)
        audioPlayer.enableRate = true
        audioPlayer.rate = playbackRate
        audioPlayer.prepareToPlay()
        player = audioPlayer
    }

    public func togglePlayback() {
        guard let player else {
            return
        }
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    public func seek(by seconds: TimeInterval) {
        guard let player else {
            return
        }
        let next = min(max(player.currentTime + seconds, 0), player.duration)
        player.currentTime = next
    }

    public func seek(to seconds: TimeInterval) {
        guard let player else {
            return
        }
        player.currentTime = min(max(seconds, 0), player.duration)
    }

    public func setRate(_ rate: Float) {
        playbackRate = rate
        player?.enableRate = true
        player?.rate = rate
    }

    public func stop() {
        player?.stop()
        player?.currentTime = 0
        player = nil
    }
}
