import ActivityKit
import Foundation

/// Darwin notification the widget extension posts after a player command, so the app refreshes immediately.
let playerCommandNotification = "com.ramych.lyrics.playerCommand"

struct LyricsActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var currentLine: String
        var nextLine: String
        var isPlaying: Bool
        var source: String
    }
}
