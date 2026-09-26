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

    let spotifyAuth: SpotifyAuth
    let appleMusic = AppleMusicSource()

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
    @ObservationIgnored private var skipToken: Int32 = 0

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [Keys.liveActivity: true, Keys.keepAlive: true, Keys.offset: 0.0])
        liveActivityEnabled = defaults.bool(forKey: Keys.liveActivity)
        keepAliveEnabled = defaults.bool(forKey: Keys.keepAlive)
        lyricsOffset = defaults.double(forKey: Keys.offset)
        let auth = SpotifyAuth()
        spotifyAuth = auth
        spotify = SpotifyClient(auth: auth)
    }

    func start() {
        guard loops.isEmpty else { return }
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
                    self?.tick()
                    try? await Task.sleep(for: .milliseconds(200))
                }
            },
        ]
        notify_register_dispatch(trackSkippedNotification, &skipToken, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DiagnosticsLog.write("skip from live activity")
                self?.pollAppleMusic()
            }
        }
        updateKeepAlive()
    }

    func appDidBecomeActive() {
        DiagnosticsLog.write("app became active")
        pollAppleMusic()
        tick()
    }

    var displayLines: (current: String, next: String) {
        switch lyrics {
        case .synced(let lines):
            guard let index = currentIndex else { return ("♪", lines.first?.text ?? "") }
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
        lyricsTask = Task { [lrclib] in
            let result: LyricsState
            do {
                switch try await lrclib.lyrics(for: track) {
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

    private func tick() {
        if let snapshot, case .synced(let lines) = lyrics {
            let position = snapshot.estimatedPosition() + lyricsOffset
            let index = LRCParser.index(in: lines, at: position)
            if index != currentIndex { currentIndex = index }
        } else if currentIndex != nil {
            currentIndex = nil
        }
        pushLiveActivity()
    }

    private func pushLiveActivity() {
        guard liveActivityEnabled, let snapshot else { return }
        let lines = displayLines
        liveActivity.update(LyricsActivityAttributes.ContentState(
            title: snapshot.track.title,
            artist: snapshot.track.artist,
            currentLine: lines.current,
            nextLine: lines.next,
            isPlaying: snapshot.isPlaying,
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
