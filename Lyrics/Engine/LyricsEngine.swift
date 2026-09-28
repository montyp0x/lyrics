import Foundation
import notify
import Observation

enum LyricsState: Equatable {
    case idle
    case loading
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
    case failed(String)
}

@MainActor
@Observable
final class LyricsEngine {
    private(set) var snapshot: PlaybackSnapshot?
    private(set) var lyrics: LyricsState = .idle
    private(set) var currentIndex: Int?
    private(set) var spotifyError: String?

    var liveActivityEnabled: Bool {
        didSet {
            defaults.set(liveActivityEnabled, forKey: Keys.liveActivity)
            if liveActivityEnabled { pushLiveActivity() } else { liveActivity.end() }
        }
    }
    var keepAliveEnabled: Bool {
        didSet {
            defaults.set(keepAliveEnabled, forKey: Keys.keepAlive)
            updateKeepAlive()
        }
    }
    /// Seconds added to the playback position; positive values show lines earlier.
    var lyricsOffset: Double {
        didSet { defaults.set(lyricsOffset, forKey: Keys.offset) }
    }

    /// `media-user-token` from music.apple.com, for Apple Music's own synced lyrics.
    var appleMusicUserToken: String {
        didSet {
            guard appleMusicUserToken != oldValue else { return }
            AppleMusicLyricsClient.userToken = appleMusicUserToken
            appleLyricsStatus = nil
            // Songs that had no synced lyrics before may have them now.
            cache = cache.filter { if case .synced = $0.value { true } else { false } }
            if let track = loadedTrack { loadLyrics(for: track) }
        }
    }
    /// Result of the last Apple Music lyrics request, shown in Settings.
    private(set) var appleLyricsStatus: String?

    let spotifyAuth: SpotifyAuth
    let appleMusic = AppleMusicSource()
    let appleLyrics = AppleMusicLyricsClient()

    private enum Keys {
        static let liveActivity = "liveActivityEnabled"
        static let keepAlive = "keepAliveEnabled"
        static let offset = "lyricsOffset"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let lrclib = LRCLibClient()
    @ObservationIgnored private let liveActivity = LiveActivityController()
    @ObservationIgnored private let keeper = BackgroundKeeper()
    @ObservationIgnored private let locationKeeper = LocationKeeper()
    @ObservationIgnored private let spotify: SpotifyClient
    @ObservationIgnored private var appleSnapshot: PlaybackSnapshot?
    @ObservationIgnored private var spotifySnapshot: PlaybackSnapshot?
    @ObservationIgnored private var loadedTrack: Track?
    @ObservationIgnored private var cache: [Track: LyricsState] = [:]
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private var playerCommandToken: Int32 = 0
    @ObservationIgnored private var liveActivityIndex: Int?
    /// A Live Activity update takes ~0.3 s to reach the screen (the widget extension re-renders it), and a line
    /// reads best slightly before it's sung, so the activity gets each line this much early.
    private static let liveActivityLead: TimeInterval = 0.65

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.liveActivity: true, Keys.keepAlive: true, Keys.offset: 0.0])
        liveActivityEnabled = defaults.bool(forKey: Keys.liveActivity)
        keepAliveEnabled = defaults.bool(forKey: Keys.keepAlive)
        lyricsOffset = defaults.double(forKey: Keys.offset)
        appleMusicUserToken = AppleMusicLyricsClient.userToken ?? ""
        let auth = SpotifyAuth()
        spotifyAuth = auth
        spotify = SpotifyClient(auth: auth)
    }

    func start() {
        guard loops.isEmpty else { return }
        ResumeNotification.requestAuthorization()
        loops = [
            Task { [weak self] in
                while !Task.isCancelled {
                    self?.pollAppleMusic()
                    try? await Task.sleep(for: .seconds(1))
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    let delay = await self?.pollSpotify() ?? .seconds(3)
                    try? await Task.sleep(for: delay)
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    let delay = self?.tick() ?? 0.2
                    try? await Task.sleep(for: .seconds(delay))
                }
            },
        ]
        notify_register_dispatch(playerCommandNotification, &playerCommandToken, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DiagnosticsLog.write("player command from live activity")
                self?.pollAppleMusic()
            }
        }
        updateKeepAlive()
    }

    func appDidBecomeActive() {
        DiagnosticsLog.write("app became active")
        liveActivity.appDidBecomeActive()
        pollAppleMusic()
        tick()
    }

    /// Lines for the Live Activity, which runs `liveActivityLead` ahead of the in-app view.
    private func displayLines(at index: Int?) -> (current: String, next: String) {
        switch lyrics {
        case .synced(let lines):
            guard let index else { return ("♪", lines.first?.text ?? "") }
            let current = lines[index].text.isEmpty ? "♪" : lines[index].text
            let next = index + 1 < lines.count ? lines[index + 1].text : ""
            return (current, next)
        case .loading: return ("Loading lyrics…", "")
        case .plain: return ("Lyrics aren't synced for this song", "")
        case .instrumental: return ("♪ Instrumental", "")
        case .notFound: return ("No lyrics found", "")
        case .failed: return ("Couldn't load lyrics", "")
        case .idle: return ("", "")
        }
    }

    @ObservationIgnored private var pollCount = 0

    private func pollAppleMusic() {
        let previous = appleSnapshot
        appleSnapshot = appleMusic.snapshot()
        pollCount += 1
        if let previous, let current = appleSnapshot, previous.track == current.track, previous.isPlaying, current.isPlaying {
            let drift = current.position - previous.estimatedPosition(at: current.capturedAt)
            if abs(drift) > 0.15 {
                DiagnosticsLog.write("apple drift \(String(format: "%+.2f", drift)) s at pos \(String(format: "%.2f", current.position))")
            }
        }
        if previous?.track != appleSnapshot?.track || previous?.isPlaying != appleSnapshot?.isPlaying || pollCount % 10 == 0 {
            DiagnosticsLog.write("apple: \(appleSnapshot.map { "\($0.track.title) playing=\($0.isPlaying) pos=\(Int($0.position))" } ?? "nil")")
        }
        refreshSnapshot()
    }

    private func pollSpotify() async -> Duration {
        guard spotifyAuth.isConnected else {
            spotifySnapshot = nil
            return .seconds(3)
        }
        do {
            spotifySnapshot = try await spotify.currentPlayback()
            spotifyError = nil
            refreshSnapshot()
            return .seconds(3)
        } catch SpotifyError.rateLimited(let retryAfter) {
            spotifyError = SpotifyError.rateLimited(retryAfter: retryAfter).localizedDescription
            return .seconds(max(retryAfter, 3))
        } catch {
            spotifyError = error.localizedDescription
            return .seconds(5)
        }
    }

    private func refreshSnapshot() {
        let candidates = [spotifySnapshot, appleSnapshot].compactMap { $0 }
        let chosen = candidates.first(where: \.isPlaying)
            ?? candidates.first(where: { $0.source == snapshot?.source })
            ?? candidates.first
        snapshot = chosen

        guard let track = chosen?.track else {
            loadedTrack = nil
            lyrics = .idle
            currentIndex = nil
            return
        }
        if track != loadedTrack {
            loadLyrics(for: track)
        }
    }

    /// Apple Music first (exact recording, when a token is set), then LRCLIB. Synced lyrics from either source
    /// beat plain text from the other.
    private func lookUpLyrics(for track: Track) async throws -> LyricsLookup {
        var apple: LyricsLookup?
        do {
            apple = try await appleLyrics.lyrics(for: track)
            if apple != nil { appleLyricsStatus = nil }
        } catch {
            appleLyricsStatus = error.localizedDescription
            DiagnosticsLog.write("apple lyrics error for \(track.title): \(error.localizedDescription)")
        }
        if case .synced = apple {
            DiagnosticsLog.write("lyrics source for \(track.title): apple music")
            return apple!
        }
        do {
            let lrc = try await lrclib.lyrics(for: track)
            if case .synced = lrc { return lrc }
            if case .plain = apple { return apple! }
            return lrc
        } catch {
            if case .plain = apple { return apple! }
            throw error
        }
    }

    private func loadLyrics(for track: Track) {
        DiagnosticsLog.write("track change -> \(track.title) / \(track.artist)")
        loadedTrack = track
        currentIndex = nil
        lyricsTask?.cancel()
        if let cached = cache[track] {
            lyrics = cached
            return
        }
        lyrics = .loading
        lyricsTask = Task {
            let result: LyricsState
            do {
                switch try await lookUpLyrics(for: track) {
                case .synced(let lines): result = .synced(lines)
                case .plain(let text): result = .plain(text)
                case .instrumental: result = .instrumental
                case .notFound: result = .notFound
                }
            } catch {
                result = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled, loadedTrack == track else { return }
            DiagnosticsLog.write("lyrics for \(track.title): \(String(describing: result).prefix(40))")
            if case .failed = result {} else { cache[track] = result }
            lyrics = result
        }
    }

    /// Updates the current lines and returns how long to wait before the next line change (capped at 200 ms).
    private func tick() -> TimeInterval {
        var delay = 0.2
        if let snapshot, case .synced(let lines) = lyrics {
            let position = snapshot.estimatedPosition() + lyricsOffset
            let index = LRCParser.index(in: lines, at: position)
            if index != currentIndex { currentIndex = index }
            liveActivityIndex = LRCParser.index(in: lines, at: position + Self.liveActivityLead)
            if snapshot.isPlaying {
                for boundary in [position, position + Self.liveActivityLead] {
                    let next = (LRCParser.index(in: lines, at: boundary)).map { $0 + 1 } ?? 0
                    if next < lines.count { delay = min(delay, lines[next].time - boundary) }
                }
            }
        } else {
            if currentIndex != nil { currentIndex = nil }
            liveActivityIndex = nil
        }
        pushLiveActivity()
        return max(delay, 0.01)
    }

    private func pushLiveActivity() {
        guard liveActivityEnabled, let snapshot else { return }
        let lines = displayLines(at: liveActivityIndex)
        liveActivity.update(LyricsActivityAttributes.ContentState(
            title: snapshot.track.title,
            artist: snapshot.track.artist,
            currentLine: lines.current,
            nextLine: lines.next,            isPlaying: snapshot.isPlaying,
            source: snapshot.source.displayName
        ))
    }

    private func updateKeepAlive() {
        if keepAliveEnabled, !loops.isEmpty {
            keeper.start()
            locationKeeper.start()
        } else {
            keeper.stop()
            locationKeeper.stop()
        }
    }
}
