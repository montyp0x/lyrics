import Foundation

/// What a lyrics source found for a track.
enum LyricsLookup: Equatable {
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
}
