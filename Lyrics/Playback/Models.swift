import Foundation

enum MusicSource: String, Codable {
    case appleMusic
    case spotify

    var displayName: String {
        switch self {
        case .appleMusic: "Apple Music"
        case .spotify: "Spotify"
        }
    }
}

struct Track: Hashable {
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval

    var primaryArtist: String {
        let separators = [", ", " & ", " feat. ", " ft. ", " featuring "]
        let first = separators.reduce(artist) { $0.components(separatedBy: $1).first ?? $0 }
        return first.isEmpty ? artist : first
    }
}

struct PlaybackSnapshot: Equatable {
    var source: MusicSource
    var track: Track
    var position: TimeInterval
    var isPlaying: Bool
    var capturedAt: Date

    func estimatedPosition(at date: Date = .now) -> TimeInterval {
        guard isPlaying else { return position }
        let estimate = position + date.timeIntervalSince(capturedAt)
        return track.duration > 0 ? min(estimate, track.duration) : estimate
    }
}
