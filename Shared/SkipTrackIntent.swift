import AppIntents
import Foundation
#if !WIDGET_EXTENSION
import MediaPlayer
#endif

extension Notification.Name {
    static let trackSkipped = Notification.Name("trackSkipped")
}

/// Skips the Apple Music queue from the Live Activity. Runs in the app process.
struct SkipTrackIntent: LiveActivityIntent {
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
        #if !WIDGET_EXTENSION
        let player = MPMusicPlayerController.systemMusicPlayer
        if forward {
            player.skipToNextItem()
        } else {
            player.skipToPreviousItem()
        }
        NotificationCenter.default.post(name: .trackSkipped, object: nil)
        #endif
        return .result()
    }
}
