import AppIntents
import Foundation
import notify
import os

enum MacPlaybackCommand: String, AppEnum {
    case previous
    case toggle
    case next

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playback")
    static var caseDisplayRepresentations: [MacPlaybackCommand: DisplayRepresentation] = [
        .previous: "Previous",
        .toggle: "Play or Pause",
        .next: "Next",
    ]
}

/// Runs in the widget extension, like the iPhone StandBy buttons. Tells Music or Spotify directly
/// so the app doesn't have to launch.
struct MacPlaybackIntent: AppIntent {
    static var title: LocalizedStringResource = "Control Playback"
    static var isDiscoverable = false
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Command")
    var command: MacPlaybackCommand

    init() {
        command = .toggle
    }

    init(command: MacPlaybackCommand) {
        self.command = command
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            MacPlayerControl.run(command)
        }
        return .result()
    }
}

@MainActor
private enum MacPlayerControl {
    private static let log = Logger(subsystem: "com.ramych.lyrics.mac.widgets", category: "playback")

    static func run(_ command: MacPlaybackCommand) {
        let source = LyricsWidgetStore.load()?.source ?? ""
        let application = source == MusicSourceName.spotify ? "Spotify" : "Music"
        let verb: String
        switch command {
        case .previous: verb = "previous track"
        case .toggle: verb = "playpause"
        case .next: verb = "next track"
        }
        let script = NSAppleScript(source: """
        tell application "\(application)"
            \(verb)
        end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? String(describing: error)
            log.error("\(application) \(verb): \(message, privacy: .public)")
        }
        notify_post(playerCommandNotification)
    }
}

private enum MusicSourceName {
    static let spotify = "spotify"
}
