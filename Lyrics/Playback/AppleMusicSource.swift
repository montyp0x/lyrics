#if os(iOS)
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
            duration: item.playbackDuration,
            appleMusicID: ["", "0"].contains(item.playbackStoreID) ? nil : item.playbackStoreID
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
#else
import StoreKit

/// Playback comes from the Music app via AppleScript (`ScriptedPlayer`). StoreKit authorization is only
/// for `requestUserToken`, which fetches Apple Music's own synced lyrics for the signed-in Apple ID.
@MainActor
final class AppleMusicSource {
    private(set) var isAuthorized = SKCloudServiceController.authorizationStatus() == .authorized

    func requestAuthorization() async -> Bool {
        let status = await withCheckedContinuation { continuation in
            SKCloudServiceController.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        isAuthorized = status == .authorized
        return isAuthorized
    }

    func snapshot() -> PlaybackSnapshot? {
        ScriptedPlayer.music.snapshot()
    }
}
#endif
