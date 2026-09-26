import AppIntents
import Foundation
import MediaPlayer
import notify

// Plain `AppIntent`s so they run in the widget extension. `LiveActivityIntent` and
// `AudioPlaybackIntent` run in the app process, and launching the app from a locked
// phone makes iOS ask for Face ID first.

/// Skips the Apple Music queue from the Live Activity.
struct SkipTrackIntent: AppIntent {
    static var title: LocalizedStringResource = "Skip Track"
    static var isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var openAppWhenRun = false

    @Parameter(title: "Forward")
    var forward: Bool

    init() {}

    init(forward: Bool) {
        self.forward = forward
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = MPMusicPlayerController.systemMusicPlayer
        if forward {
            player.skipToNextItem()
        } else {
            player.skipToPreviousItem()
        }
        notify_post(playerCommandNotification)
        return .result()
    }
}

/// Toggles Apple Music between playing and paused from the Live Activity.
struct TogglePlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Play or Pause"
    static var isDiscoverable = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        let player = MPMusicPlayerController.systemMusicPlayer
        if player.playbackState == .playing {
            player.pause()
        } else {
            player.play()
        }
        notify_post(playerCommandNotification)
        return .result()
    }
}
