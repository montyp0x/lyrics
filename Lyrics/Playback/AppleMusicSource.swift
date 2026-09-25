import MediaPlayer

@MainActor
final class AppleMusicSource {
    private let player = MPMusicPlayerController.systemMusicPlayer

    var isAuthorized: Bool {
        MPMediaLibrary.authorizationStatus() == .authorized
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func snapshot() -> PlaybackSnapshot? {
        guard isAuthorized, let item = player.nowPlayingItem, let title = item.title else { return nil }
        let track = Track(
            title: title,
            artist: item.artist ?? "",
            album: item.albumTitle ?? "",
            duration: item.playbackDuration
        )
        let position = player.currentPlaybackTime
        return PlaybackSnapshot(
            source: .appleMusic,
            track: track,
            position: position.isFinite ? position : 0,
            isPlaying: player.playbackState == .playing,
            capturedAt: .now
        )
    }
}
