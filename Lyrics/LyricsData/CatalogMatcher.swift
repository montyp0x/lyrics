import Foundation

/// Picks the Apple Music catalog song that is the same recording as a track from another source (Spotify).
enum CatalogMatcher {
    struct Candidate: Equatable {
        let id: String
        let title: String
        let artist: String
        let durationInMillis: Int?
    }

    /// Same cleaned title, and either the same artist within 3 s of the duration, or (when the artist is
    /// spelled differently, e.g. Cyrillic vs Latin) within 1 s. Artist matches win over duration-only ones.
    static func bestMatch(for track: Track, in candidates: [Candidate]) -> Candidate? {
        let title = normalize(LRCLibClient.cleanTitle(track.title))
        let artist = normalize(track.primaryArtist)
        let sameTitle = candidates.filter { normalize(LRCLibClient.cleanTitle($0.title)) == title }

        func gap(_ candidate: Candidate) -> TimeInterval {
            guard track.duration > 0 else { return 0 }
            return abs(Double(candidate.durationInMillis ?? 0) / 1000 - track.duration)
        }
        func sameArtist(_ candidate: Candidate) -> Bool {
            let other = normalize(candidate.artist)
            return !artist.isEmpty && (other.contains(artist) || artist.contains(other))
        }

        if let match = sameTitle.filter({ sameArtist($0) && gap($0) < 3 }).min(by: { gap($0) < gap($1) }) {
            return match
        }
        guard track.duration > 0 else { return nil }
        return sameTitle.filter { gap($0) < 1 }.min { gap($0) < gap($1) }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespaces)
    }
}
