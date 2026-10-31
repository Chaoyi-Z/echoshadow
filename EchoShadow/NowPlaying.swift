import MediaPlayer

/// Lock-screen and headphone controls while Read all is running.
@MainActor
enum NowPlaying {
    private static var targets: [(MPRemoteCommand, Any)] = []

    static func activate(play: @escaping @MainActor () -> Void,
                         pause: @escaping @MainActor () -> Void,
                         next: @escaping @MainActor () -> Void,
                         previous: @escaping @MainActor () -> Void) {
        deactivate()
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor () -> Void) {
            command.isEnabled = true
            let token = command.addTarget { _ in
                MainActor.assumeIsolated { action() }
                return .success
            }
            targets.append((command, token))
        }
        add(center.playCommand, play)
        add(center.pauseCommand, pause)
        add(center.togglePlayPauseCommand) { if isPlaying { pause() } else { play() } }
        add(center.nextTrackCommand, next)
        add(center.previousTrackCommand, previous)
    }

    private static var isPlaying = false

    static func update(title: String, sentence: String, position: Int, total: Int, playing: Bool) {
        isPlaying = playing
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Sentence \(position + 1) of \(total)",
            MPMediaItemPropertyAlbumTitle: String(sentence.prefix(120)),
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackProgress: total > 0 ? Double(position) / Double(total) : 0,
        ]
    }

    static func deactivate() {
        for (command, token) in targets { command.removeTarget(token) }
        targets.removeAll()
        isPlaying = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
