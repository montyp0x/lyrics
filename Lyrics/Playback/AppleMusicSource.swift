import MediaPlayer

@MainActor
final class AppleMusicSource {
    private let player = MPMusicPlayerController.systemMusicPlayer

    /// Cached because every status check is an IPC round trip, and snapshots are taken every second.
    private(set) var isAuthorized = MPMediaLibrary.authorizationStatus() == .authorized

    func requestAuthorization() async -> Bool {
        isAuthorized = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return isAuthorized
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
