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
        /// Index of `currentLine` in the lyrics (-1 before the first line or when there are no synced lyrics);
        /// the widget uses it to keep a line's identity as it moves from "next" to "current".
        var lineIndex: Int
        var isPlaying: Bool
        var source: String
    }
}
