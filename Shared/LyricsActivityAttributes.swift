import ActivityKit
import Foundation

/// Darwin notification the widget extension posts after skipping, so the app refreshes immediately.
let trackSkippedNotification = "com.ramych.lyrics.trackSkipped"

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
