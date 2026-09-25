import Foundation

/// Client for https://lrclib.net, a free community database of synced lyrics.
struct LRCLibClient {
    enum Lookup: Equatable {
        case synced([LyricLine])
        case plain(String)
        case instrumental
        case notFound
    }

    private struct Record: Decodable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    enum Failure: LocalizedError {
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .http(let status): "LRCLIB returned HTTP \(status)"
            }
        }
    }

    private let baseURL = URL(string: "https://lrclib.net/api")!
    var session: URLSession = .shared

    func lyrics(for track: Track) async throws -> Lookup {
        var fallback: Lookup?
        if let record = try await exactMatch(for: track) {
            fallback = Self.lookup(from: record)
            if case .synced = fallback { return fallback! }
        }

        // Entries are often filed under a different title/artist split, e.g. "Song (feat. X)" by "A"
        // versus "Song" by "A feat. X", so try looser searches before settling for plain lyrics.
        let title = Self.cleanTitle(track.title)
        let searches: [[URLQueryItem]] = [
            [URLQueryItem(name: "track_name", value: title), URLQueryItem(name: "artist_name", value: track.primaryArtist)],
            [URLQueryItem(name: "q", value: "\(title) \(track.primaryArtist)")],
        ]
        var candidates: [Record] = []
        var searchError: Error?
        for query in searches {
            do {
                let records = try await search(query)
                if let synced = Self.bestSynced(in: records, for: track) { return synced }
                candidates += records
            } catch {
                searchError = error
            }
        }
        if let lookup = fallback ?? candidates.lazy.compactMap(Self.lookup(from:)).first { return lookup }
        if let searchError { throw searchError }
        return .notFound
    }

    static func cleanTitle(_ title: String) -> String {
        let cleaned = titleNoise
            .reduce(title) { $0.replacing($1, with: "") }
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? title : cleaned
    }

    private static let titleNoise: [Regex<AnyRegexOutput>] = [
        #"\s*[\(\[](feat\.?|ft\.?|featuring|with)\s[^\)\]]*[\)\]]"#,
        #"\s*[\(\[][^\)\]]*(remaster|version|edit|mono|stereo|deluxe)[^\)\]]*[\)\]]"#,
        #"\s+-\s+[^-]*(remaster|version|edit|mono|stereo|live)[^-]*$"#,
    ].map { try! Regex($0).ignoresCase() }

    private static func bestSynced(in records: [Record], for track: Track) -> Lookup? {
        records
            .filter { $0.syncedLyrics?.isEmpty == false && durationGap($0, track) < 5 }
            .min { durationGap($0, track) < durationGap($1, track) }
            .flatMap(lookup(from:))
    }

    private func exactMatch(for track: Track) async throws -> Record? {
        var query = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.primaryArtist),
        ]
        if !track.album.isEmpty {
            query.append(URLQueryItem(name: "album_name", value: track.album))
        }
        if track.duration > 0 {
            query.append(URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))))
        }
        let (data, status) = try await get("get", query: query)
        if status == 404 || status >= 500 { return nil }
        guard status == 200 else { throw Failure.http(status) }
        return try JSONDecoder().decode(Record.self, from: data)
    }

    private func search(_ query: [URLQueryItem]) async throws -> [Record] {
        let (data, status) = try await get("search", query: query)
        guard status == 200 else { throw Failure.http(status) }
        return try JSONDecoder().decode([Record].self, from: data)
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> (Data, Int) {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.setValue("Lyrics iOS (private use)", forHTTPHeaderField: "User-Agent")
        var (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 500 {
            try await Task.sleep(for: .seconds(1))
            (data, response) = try await session.data(for: request)
        }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func lookup(from record: Record) -> Lookup? {
        if record.instrumental == true { return .instrumental }
        if let synced = record.syncedLyrics, !synced.isEmpty {
            let lines = LRCParser.parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = record.plainLyrics, !plain.isEmpty { return .plain(plain) }
        return nil
    }

    private static func durationGap(_ record: Record, _ track: Track) -> TimeInterval {
        guard track.duration > 0, let duration = record.duration else { return 0 }
        return abs(duration - track.duration)
    }
}
