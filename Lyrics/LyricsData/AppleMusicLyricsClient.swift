import Foundation
import StoreKit

/// Apple Music's own time-synced lyrics, from the API behind music.apple.com.
///
/// Needs the `media-user-token` cookie of a signed-in music.apple.com session (entered in Settings).
/// The developer token is the one the web player ships in its JavaScript bundle; it's scraped and cached
/// until it expires. Both are unofficial and may stop working if Apple changes the web player.
actor AppleMusicLyricsClient {
    enum Failure: LocalizedError {
        case unauthorized
        case http(Int)
        case noDeveloperToken

        var errorDescription: String? {
            switch self {
            case .unauthorized: "Apple Music rejected the media-user-token. Copy a fresh one from music.apple.com."
            case .http(let status): "Apple Music returned HTTP \(status)"
            case .noDeveloperToken: "Couldn't read the developer token from music.apple.com"
            }
        }
    }

    private static let userTokenAccount = "appleMusicUserToken"
    private static let apiBase = URL(string: "https://amp-api.music.apple.com/v1")!
    private static let webBase = URL(string: "https://music.apple.com")!
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private enum Keys {
        static let developerToken = "appleMusicDeveloperToken"
        static let storefront = "appleMusicStorefront"
    }

    static var userToken: String? {
        get { Keychain.data(for: userTokenAccount).flatMap { String(data: $0, encoding: .utf8) } }
        set {
            let token = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            Keychain.set(token.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, for: userTokenAccount)
            UserDefaults.standard.removeObject(forKey: Keys.storefront)
        }
    }

    private let session: URLSession
    private let defaults = UserDefaults.standard

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Returns nil when no user token is configured, so callers fall back to other sources.
    func lyrics(for track: Track) async throws -> LyricsLookup? {
        guard let userToken = Self.userToken else { return nil }
        let storefront = try await storefront(userToken: userToken)
        guard let id = try await catalogID(for: track, storefront: storefront, userToken: userToken) else { return .notFound }

        let (data, status) = try await get("catalog/\(storefront)/songs/\(id)/lyrics", userToken: userToken)
        if status == 404 { return .notFound }
        guard status == 200 else { throw Failure.http(status) }
        let response = try JSONDecoder().decode(LyricsResponse.self, from: data)
        guard let ttml = response.data.first?.attributes.ttml else { return .notFound }
        return TTMLParser.parse(ttml)
    }

    /// Asks StoreKit for the Music User Token of the Apple ID signed in on this device, using the web
    /// player's developer token. No login needed; requires Apple Music (media library) permission.
    func requestDeviceUserToken() async throws -> String {
        let developerToken = try await developerToken()
        return try await withCheckedThrowingContinuation { continuation in
            SKCloudServiceController().requestUserToken(forDeveloperToken: developerToken) { token, error in
                if let token {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: error ?? Failure.unauthorized)
                }
            }
        }
    }

    /// Checks the token by asking for the account's storefront.
    func verify() async throws -> String {
        guard let userToken = Self.userToken else { throw Failure.unauthorized }
        defaults.removeObject(forKey: Keys.storefront)
        return try await storefront(userToken: userToken)
    }

    // MARK: - Catalog

    private func catalogID(for track: Track, storefront: String, userToken: String) async throws -> String? {
        if let id = track.appleMusicID { return id }
        // Spotify tracks have no Apple Music ID; find the same recording by name, artist, and duration.
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "term", value: "\(LRCLibClient.cleanTitle(track.title)) \(track.primaryArtist)"),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        let (data, status) = try await get("catalog/\(storefront)/search", query: components.queryItems, userToken: userToken)
        guard status == 200 else { throw Failure.http(status) }
        let songs = try JSONDecoder().decode(SearchResponse.self, from: data).results.songs?.data ?? []
        let title = LRCLibClient.cleanTitle(track.title).lowercased()
        return songs.first { song in
            let sameTitle = LRCLibClient.cleanTitle(song.attributes.name).lowercased() == title
            let durationGap = abs(Double(song.attributes.durationInMillis ?? 0) / 1000 - track.duration)
            return sameTitle && (track.duration <= 0 || durationGap < 3)
        }?.id
    }

    private func storefront(userToken: String) async throws -> String {
        if let cached = defaults.string(forKey: Keys.storefront) { return cached }
        let (data, status) = try await get("me/storefront", userToken: userToken)
        guard status == 200 else { throw status == 401 || status == 403 ? Failure.unauthorized : Failure.http(status) }
        let storefront = try JSONDecoder().decode(StorefrontResponse.self, from: data).data.first?.id ?? "us"
        defaults.set(storefront, forKey: Keys.storefront)
        return storefront
    }

    // MARK: - Requests

    private func get(_ path: String, query: [URLQueryItem]? = nil, userToken: String) async throws -> (Data, Int) {
        var components = URLComponents(url: Self.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        var (data, status) = try await send(components.url!, userToken: userToken, developerToken: developerToken())
        if status == 401 {
            // The scraped developer token may have been rotated; fetch a fresh one once.
            defaults.removeObject(forKey: Keys.developerToken)
            (data, status) = try await send(components.url!, userToken: userToken, developerToken: developerToken())
            if status == 401 { throw Failure.unauthorized }
        }
        return (data, status)
    }

    private func send(_ url: URL, userToken: String, developerToken: String) async throws -> (Data, Int) {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userToken, forHTTPHeaderField: "Media-User-Token")
        request.setValue(Self.webBase.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(Self.webBase.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func developerToken() async throws -> String {
        if let cached = defaults.string(forKey: Keys.developerToken), Self.expiry(of: cached) ?? .distantPast > .now {
            return cached
        }
        let html = try await fetchText(Self.webBase.appendingPathComponent("us/browse"))
        let scripts = html.matches(of: #/src="(/assets/index[^"]*\.js)"/#).map { String($0.output.1) }
        for script in scripts {
            let js = try await fetchText(URL(string: script, relativeTo: Self.webBase)!)
            let tokens = js.matches(of: #/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/#).map { String($0.output) }
            if let token = tokens.first(where: { Self.issuer(of: $0) == "AMPWebPlay" }) ?? tokens.first {
                defaults.set(token, forKey: Keys.developerToken)
                return token
            }
        }
        throw Failure.noDeveloperToken
    }

    private func fetchText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }

    private static func claims(of jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func issuer(of jwt: String) -> String? { claims(of: jwt)?["iss"] as? String }

    private static func expiry(of jwt: String) -> Date? {
        (claims(of: jwt)?["exp"] as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    // MARK: - Responses

    private struct LyricsResponse: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable { let ttml: String? }
            let attributes: Attributes
        }
        let data: [Item]
    }

    private struct SearchResponse: Decodable {
        struct Results: Decodable {
            struct Songs: Decodable { let data: [Song] }
            let songs: Songs?
        }
        struct Song: Decodable {
            struct Attributes: Decodable {
                let name: String
                let durationInMillis: Int?
            }
            let id: String
            let attributes: Attributes
        }
        let results: Results
    }

    private struct StorefrontResponse: Decodable {
        struct Item: Decodable { let id: String }
        let data: [Item]
    }
}
