import CryptoKit
import Foundation
import Observation

enum SpotifyError: LocalizedError {
    case missingClientID
    case notConnected
    case authorizationFailed(String)
    case rateLimited(retryAfter: TimeInterval)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "Enter your Spotify client ID first."
        case .notConnected: "Spotify isn't connected."
        case .authorizationFailed(let reason): "Spotify login failed: \(reason)"
        case .rateLimited(let seconds): "Spotify rate limit hit, retrying in \(Int(seconds))s."
        case .http(let status, let body): "Spotify returned HTTP \(status). \(body)"
        }
    }
}

/// Authorization Code flow with PKCE, so no client secret has to ship in the app.
@MainActor
@Observable
final class SpotifyAuth {
    static let redirectURI = "lyrics-app://spotify-callback"
    static let callbackScheme = "lyrics-app"
    private static let scopes = "user-read-currently-playing user-read-playback-state"
    private static let clientIDKey = "spotifyClientID"
    private static let tokensKey = "spotifyTokens"

    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
    }

    var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: Self.clientIDKey) }
    }
    private(set) var isConnected = false

    @ObservationIgnored private var tokens: Tokens? {
        didSet {
            isConnected = tokens != nil
            Keychain.set(tokens.flatMap { try? JSONEncoder().encode($0) }, for: Self.tokensKey)
        }
    }
    @ObservationIgnored private var pendingVerifier: String?
    @ObservationIgnored private var refreshTask: Task<Tokens, Error>?

    init() {
        clientID = UserDefaults.standard.string(forKey: Self.clientIDKey) ?? ""
        if let data = Keychain.data(for: Self.tokensKey), let saved = try? JSONDecoder().decode(Tokens.self, from: data) {
            tokens = saved
            isConnected = true
        }
    }

    private var trimmedClientID: String {
        clientID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func authorizationURL() throws -> URL {
        guard !trimmedClientID.isEmpty else { throw SpotifyError.missingClientID }
        let verifier = Self.makeVerifier()
        pendingVerifier = verifier
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: trimmedClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "scope", value: Self.scopes),
        ]
        return components.url!
    }

    func completeAuthorization(callbackURL: URL) async throws {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw SpotifyError.authorizationFailed(error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, let verifier = pendingVerifier else {
            throw SpotifyError.authorizationFailed("missing authorization code")
        }
        pendingVerifier = nil
        tokens = try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": trimmedClientID,
            "code_verifier": verifier,
        ], previousRefreshToken: nil)
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        tokens = nil
    }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw SpotifyError.notConnected }
        if !forceRefresh, current.expiresAt > .now.addingTimeInterval(60) {
            return current.accessToken
        }
        if let refreshTask {
            return try await refreshTask.value.accessToken
        }
        let task = Task {
            try await requestTokens([
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": trimmedClientID,
            ], previousRefreshToken: current.refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            tokens = refreshed
            return refreshed.accessToken
        } catch SpotifyError.http(let status, _) where status == 400 {
            // invalid_grant: the refresh token was revoked, so the user has to log in again.
            tokens = nil
            throw SpotifyError.notConnected
        }
    }

    private func requestTokens(_ parameters: [String: String], previousRefreshToken: String?) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(parameters).utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw SpotifyError.http(status, String(decoding: data, as: UTF8.self))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let body = try decoder.decode(TokenResponse.self, from: data)
        guard let refreshToken = body.refreshToken ?? previousRefreshToken else {
            throw SpotifyError.authorizationFailed("no refresh token returned")
        }
        return Tokens(
            accessToken: body.accessToken,
            refreshToken: refreshToken,
            expiresAt: .now.addingTimeInterval(TimeInterval(body.expiresIn))
        )
    }

    private static let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func makeVerifier() -> String {
        String((0..<64).map { _ in unreserved.randomElement()! })
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncode(_ parameters: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: String(unreserved))
        return parameters
            .map { key, value in
                "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
            }
            .joined(separator: "&")
    }
}
