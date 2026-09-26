import AppIntents
import Foundation
import MediaPlayer
import notify

/// Skips the Apple Music queue from the Live Activity.
///
/// A plain `AppIntent` so it runs in the widget extension. `LiveActivityIntent` and
/// `AudioPlaybackIntent` run in the app process, and launching the app from a locked
/// phone makes iOS ask for Face ID first.
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
        notify_post(trackSkippedNotification)
        return .result()
    }
}
