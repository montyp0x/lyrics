import ActivityKit
import Foundation

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
