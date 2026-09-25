import Foundation

@MainActor
final class SpotifyClient {
    private struct CurrentlyPlaying: Decodable {
        struct Item: Decodable {
            struct Artist: Decodable { let name: String }
            struct Album: Decodable { let name: String }

            let name: String
            let durationMs: Int
            let artists: [Artist]?
            let album: Album?
        }

        let progressMs: Int?
        let isPlaying: Bool
        let item: Item?
    }

    private let auth: SpotifyAuth

    init(auth: SpotifyAuth) {
        self.auth = auth
    }

    func currentPlayback() async throws -> PlaybackSnapshot? {
        let startedAt = Date.now
        var (data, response) = try await fetchCurrentlyPlaying(forceRefresh: false)
        if response.statusCode == 401 {
            (data, response) = try await fetchCurrentlyPlaying(forceRefresh: true)
        }

        switch response.statusCode {
        case 200: break
        case 204: return nil
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 5
            throw SpotifyError.rateLimited(retryAfter: retryAfter)
        default:
            throw SpotifyError.http(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        guard !data.isEmpty else { return nil }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let playing = try decoder.decode(CurrentlyPlaying.self, from: data)
        // Podcast episodes come back without artists; only songs get lyrics.
        guard let item = playing.item, let artists = item.artists else { return nil }

        let track = Track(
            title: item.name,
            artist: artists.map(\.name).joined(separator: ", "),
            album: item.album?.name ?? "",
            duration: TimeInterval(item.durationMs) / 1000
        )
        let roundTrip = Date.now.timeIntervalSince(startedAt)
        return PlaybackSnapshot(
            source: .spotify,
            track: track,
            position: TimeInterval(playing.progressMs ?? 0) / 1000,
            isPlaying: playing.isPlaying,
            capturedAt: startedAt.addingTimeInterval(roundTrip / 2)
        )
    }

    private func fetchCurrentlyPlaying(forceRefresh: Bool) async throws -> (Data, HTTPURLResponse) {
        let token = try await auth.accessToken(forceRefresh: forceRefresh)
        var request = URLRequest(
            url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!,
            timeoutInterval: 10
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}
