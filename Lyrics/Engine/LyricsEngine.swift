import Foundation
import Observation
import WidgetKit
import notify

enum LyricsState: Equatable {
    case idle
    case loading
    case synced([LyricLine])
    case plain(String)
    case instrumental
    case notFound
    case failed(String)

    init(_ lookup: LyricsLookup) {
        switch lookup {
        case .synced(let lines): self = .synced(lines)
        case .plain(let text): self = .plain(text)
        case .instrumental: self = .instrumental
        case .notFound: self = .notFound
        }
    }
}

@MainActor
@Observable
final class LyricsEngine {
    private(set) var snapshot: PlaybackSnapshot?
    private(set) var lyrics: LyricsState = .idle
    private(set) var currentIndex: Int?
    private(set) var spotifyError: String?
    #if os(macOS)
    /// macOS Automation permission for the Music or Spotify app, when it has been denied.
    private(set) var playbackAccessError: String?
    #endif

    #if os(iOS)
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
    #else
    var menuBarEnabled: Bool {
        didSet { defaults.set(menuBarEnabled, forKey: Keys.menuBar) }
    }
    var floatWindow: Bool {
        didSet { defaults.set(floatWindow, forKey: Keys.floatWindow) }
    }
    #endif
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
            diskCache.removeUnsynced()
            if let track = loadedTrack { loadLyrics(for: track) }
        }
    }
    /// Result of the last Apple Music lyrics request, shown in Settings.
    private(set) var appleLyricsStatus: String?
    @ObservationIgnored private var reconnectingAppleMusic = false

    let spotifyAuth: SpotifyAuth
    let appleMusic = AppleMusicSource()
    let appleLyrics = AppleMusicLyricsClient()

    private enum Keys {
        #if os(iOS)
        static let liveActivity = "liveActivityEnabled"
        static let keepAlive = "keepAliveEnabled"
        #else
        static let menuBar = "menuBarEnabled"
        static let floatWindow = "floatWindow"
        #endif
        static let offset = "lyricsOffset"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let lrclib = LRCLibClient()
    @ObservationIgnored private let diskCache = LyricsDiskCache.shared
    #if os(iOS)
    @ObservationIgnored private let liveActivity = LiveActivityController()
    @ObservationIgnored private let keeper = BackgroundKeeper()
    @ObservationIgnored private let locationKeeper = LocationKeeper()
    #endif
    @ObservationIgnored private let spotify: SpotifyClient
    @ObservationIgnored private var appleSnapshot: PlaybackSnapshot?
    @ObservationIgnored private var spotifySnapshot: PlaybackSnapshot?
    @ObservationIgnored private var loadedTrack: Track?
    @ObservationIgnored private var cache: [Track: LyricsState] = [:]
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    /// Separate from `loops` so a state change (play, track, lyrics) can wake it from a long idle sleep.
    @ObservationIgnored private var tickLoop: Task<Void, Never>?
    /// How often the line timer runs while nothing is playing or there are no synced lyrics.
    private static let idleTickInterval: TimeInterval = 1
    @ObservationIgnored private var playerCommandToken: Int32 = 0
    /// Last timeline handed to the home-screen widget. A matching key and a position within a second of playback
    /// means the widget already has the right future lines, so it isn't rewritten on every tick.
    @ObservationIgnored private var widgetAnchor: (key: String, position: TimeInterval, date: Date)?
    @ObservationIgnored private var lastWidgetError: String?
    @ObservationIgnored private var lastWidgetReload: Date?
    @ObservationIgnored private var widgetReloadTask: Task<Void, Never>?
    #if os(iOS)
    @ObservationIgnored private var liveActivityIndex: Int?
    /// A Live Activity update takes ~0.3 s to reach the screen (the widget extension re-renders it), and a line
    /// reads best slightly before it's sung, so the activity gets each line this much early.
    private static let liveActivityLead: TimeInterval = 0.65
    #endif

    init() {
        let defaults = UserDefaults.standard
        #if os(iOS)
        defaults.register(defaults: [Keys.liveActivity: true, Keys.keepAlive: true, Keys.offset: 0.0])
        liveActivityEnabled = defaults.bool(forKey: Keys.liveActivity)
        keepAliveEnabled = defaults.bool(forKey: Keys.keepAlive)
        #else
        defaults.register(defaults: [Keys.menuBar: true, Keys.floatWindow: false, Keys.offset: 0.0])
        menuBarEnabled = defaults.bool(forKey: Keys.menuBar)
        floatWindow = defaults.bool(forKey: Keys.floatWindow)
        #endif
        lyricsOffset = defaults.double(forKey: Keys.offset)
        appleMusicUserToken = AppleMusicLyricsClient.userToken ?? ""
        let auth = SpotifyAuth()
        spotifyAuth = auth
        spotify = SpotifyClient(auth: auth)
    }

    func start() {
        guard loops.isEmpty else { return }
        #if os(iOS)
        ResumeNotification.requestAuthorization()
        #endif
        var connectOnLaunch = appleMusicUserToken.isEmpty
        #if DEBUG
        // `devicectl device process launch … com.ramych.lyrics -connectAppleMusic` re-runs the device-token flow.
        connectOnLaunch = connectOnLaunch || CommandLine.arguments.contains("-connectAppleMusic")
        #endif
        if connectOnLaunch, appleMusic.isAuthorized {
            Task { await connectAppleMusicLyrics() }
        }
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
        ]
        restartTickLoop()
        notify_register_dispatch(playerCommandNotification, &playerCommandToken, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                DiagnosticsLog.write("player command")
                self?.pollAppleMusic()
                #if os(macOS)
                Task { _ = await self?.pollSpotify() }
                #endif
            }
        }
        #if os(iOS)
        updateKeepAlive()
        #endif
    }

    func appDidBecomeActive() {
        DiagnosticsLog.write("app became active")
        #if os(iOS)
        liveActivity.appDidBecomeActive()
        #endif
        pollAppleMusic()
        tick()
    }

    #if os(iOS)
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
    #endif

    @ObservationIgnored private var pollCount = 0

    private func pollAppleMusic() {
        let previous = appleSnapshot
        appleSnapshot = appleMusic.snapshot()
        #if os(macOS)
        playbackAccessError = ScriptedPlayer.accessError
        #endif
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
        #if os(macOS)
        // The desktop app reports position without a Spotify developer app. The Web API below still covers
        // playback on other devices, and wins when the desktop app is paused.
        let local = ScriptedPlayer.spotify.snapshot()
        if local?.isPlaying == true {
            spotifySnapshot = local
            spotifyError = nil
            refreshSnapshot()
            return .seconds(1)
        }
        #endif
        guard spotifyAuth.isConnected else {
            #if os(macOS)
            spotifySnapshot = local
            refreshSnapshot()
            return .seconds(1)
            #else
            spotifySnapshot = nil
            return .seconds(3)
            #endif
        }
        do {
            let remote = try await spotify.currentPlayback()
            spotifyError = nil
            #if os(macOS)
            spotifySnapshot = remote?.isPlaying == true ? remote : (local ?? remote)
            #else
            spotifySnapshot = remote
            #endif
            refreshSnapshot()
            return .seconds(3)
        } catch SpotifyError.rateLimited(let retryAfter) {
            spotifyError = SpotifyError.rateLimited(retryAfter: retryAfter).localizedDescription
            #if os(macOS)
            if let local {
                spotifySnapshot = local
                refreshSnapshot()
            }
            #endif
            return .seconds(max(retryAfter, 3))
        } catch {
            spotifyError = error.localizedDescription
            #if os(macOS)
            if let local {
                spotifySnapshot = local
                refreshSnapshot()
            }
            #endif
            return .seconds(5)
        }
    }

    /// Runs `tick` now and then again whenever it asks. Restarted on every state change that can shorten the
    /// wait, because an idle tick sleeps for a whole second.
    private func restartTickLoop() {
        tickLoop?.cancel()
        tickLoop = Task { [weak self] in
            while !Task.isCancelled {
                let delay = self?.tick() ?? Self.idleTickInterval
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private func refreshSnapshot() {
        let candidates = [spotifySnapshot, appleSnapshot].compactMap { $0 }
        let chosen = candidates.first(where: \.isPlaying)
            ?? candidates.first(where: { $0.source == snapshot?.source })
            ?? candidates.first
        let previous = snapshot
        snapshot = chosen
        if tickLoop != nil, previous?.track != chosen?.track || previous?.isPlaying != chosen?.isPlaying {
            restartTickLoop()
        }

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

    /// Gets the Music User Token of the Apple ID on this iPhone, so Apple Music lyrics work without pasting one.
    @discardableResult
    func connectAppleMusicLyrics() async -> String {
        do {
            let token = try await appleLyrics.requestDeviceUserToken()
            DiagnosticsLog.write("apple music device token: \(token.count) chars")
            let previous = appleMusicUserToken
            appleMusicUserToken = token
            let storefront: String
            do {
                storefront = try await appleLyrics.verify()
            } catch {
                appleMusicUserToken = previous
                throw error
            }
            DiagnosticsLog.write("apple music device token works, storefront \(storefront)")
            return "✓ Connected (storefront \(storefront.uppercased()))"
        } catch {
            DiagnosticsLog.write("apple music device token failed: \(error)")
            return "✗ \(error.localizedDescription)"
        }
    }

    /// Apple Music first (exact recording, when a token is set), then LRCLIB. Synced lyrics from either source
    /// beat plain text from the other. `appleFailed` means Apple Music errored, so a non-synced result may be
    /// incomplete and shouldn't be cached on disk.
    private func lookUpLyrics(for track: Track) async throws -> (lookup: LyricsLookup, appleFailed: Bool) {
        var apple: LyricsLookup?
        var appleFailed = false
        do {
            apple = try await appleLyrics.lyrics(for: track)
            if apple != nil { appleLyricsStatus = nil }
        } catch {
            appleFailed = true
            appleLyricsStatus = error.localizedDescription
            DiagnosticsLog.write("apple lyrics error for \(track.title): \(error.localizedDescription)")
            if case AppleMusicLyricsClient.Failure.unauthorized = error, !reconnectingAppleMusic {
                // The user token expired or was revoked; get a new one from the device.
                reconnectingAppleMusic = true
                Task {
                    await connectAppleMusicLyrics()
                    reconnectingAppleMusic = false
                }
            }
        }
        if let apple, case .synced = apple {
            DiagnosticsLog.write("lyrics source for \(track.title): apple music")
            return (apple, false)
        }
        do {
            let lrc = try await lrclib.lyrics(for: track)
            if case .synced = lrc { return (lrc, false) }
            if let apple, case .plain = apple { return (apple, appleFailed) }
            return (lrc, appleFailed)
        } catch {
            if let apple, case .plain = apple { return (apple, appleFailed) }
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
        if let saved = diskCache.load(track) {
            DiagnosticsLog.write("lyrics for \(track.title) from disk cache")
            let state = LyricsState(saved)
            cache[track] = state
            lyrics = state
            return
        }
        lyrics = .loading
        lyricsTask = Task {
            let result: LyricsState
            do {
                let (lookup, appleFailed) = try await lookUpLyrics(for: track)
                if !appleFailed { diskCache.save(lookup, for: track) }
                result = LyricsState(lookup)
            } catch {
                result = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled, loadedTrack == track else { return }
            DiagnosticsLog.write("lyrics for \(track.title): \(String(describing: result).prefix(40))")
            if case .failed = result {} else { cache[track] = result }
            lyrics = result
            restartTickLoop()
        }
    }

    /// Updates the current lines and returns how long to wait before the next line change: at most 200 ms
    /// while synced lyrics play, otherwise `idleTickInterval`.
    @discardableResult
    private func tick() -> TimeInterval {
        var delay = Self.idleTickInterval
        if let snapshot, case .synced(let lines) = lyrics {
            if snapshot.isPlaying { delay = 0.2 }
            let position = snapshot.estimatedPosition() + lyricsOffset
            let index = LRCParser.index(in: lines, at: position)
            if index != currentIndex { currentIndex = index }
            #if os(iOS)
            liveActivityIndex = LRCParser.index(in: lines, at: position + Self.liveActivityLead)
            let boundaries = [position, position + Self.liveActivityLead]
            #else
            let boundaries = [position]
            #endif
            if snapshot.isPlaying {
                for boundary in boundaries {
                    let next = (LRCParser.index(in: lines, at: boundary)).map { $0 + 1 } ?? 0
                    if next < lines.count { delay = min(delay, lines[next].time - boundary) }
                }
            }
        } else {
            if currentIndex != nil { currentIndex = nil }
            #if os(iOS)
            liveActivityIndex = nil
            #endif
        }
        #if os(iOS)
        pushLiveActivity()
        #endif
        publishWidgetTimeline()
        return max(delay, 0.01)
    }

    private func publishWidgetTimeline() {
        let now = Date()
        let position = snapshot.map { $0.estimatedPosition() + lyricsOffset } ?? 0
        let key = widgetTimelineKey()
        if let anchor = widgetAnchor, anchor.key == key {
            let expected = snapshot?.isPlaying == true
                ? anchor.position + now.timeIntervalSince(anchor.date)
                : anchor.position
            if abs(position - expected) < 1 { return }
        }
        let state = LyricsWidgetState(
            title: snapshot?.track.title ?? "",
            artist: snapshot?.track.artist ?? "",
            source: snapshot?.source.rawValue ?? "",
            isPlaying: snapshot?.isPlaying ?? false,
            lines: widgetLines(),
            anchorPosition: position,
            anchorDate: now,
            message: widgetMessage()
        )
        do {
            try LyricsWidgetStore.save(state)
            widgetAnchor = (key, position, now)
            reloadWidgetTimeline()
            DiagnosticsLog.write("widget timeline \(state.title.isEmpty ? "idle" : state.title) playing=\(state.isPlaying) lines=\(state.lines.count)")
        } catch {
            let message = error.localizedDescription
            if message != lastWidgetError {
                lastWidgetError = message
                DiagnosticsLog.write("widget save failed: \(message) url=\(LyricsWidgetStore.fileURL.path)")
            }
        }
    }

    /// iOS drops widget reloads when they arrive in a burst, and then keeps the previous song's
    /// timeline. Save every change, but reload at most once every couple of seconds, trailing the burst.
    private func reloadWidgetTimeline() {
        let now = Date()
        if let lastWidgetReload, now.timeIntervalSince(lastWidgetReload) < 2 {
            widgetReloadTask?.cancel()
            widgetReloadTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                WidgetCenter.shared.reloadTimelines(ofKind: LyricsWidgetState.kind)
                self.lastWidgetReload = Date()
                DiagnosticsLog.write("widget reload")
            }
            return
        }
        widgetReloadTask?.cancel()
        WidgetCenter.shared.reloadTimelines(ofKind: LyricsWidgetState.kind)
        lastWidgetReload = now
        DiagnosticsLog.write("widget reload")
    }

    private func widgetTimelineKey() -> String {
        let track = snapshot.map { "\($0.track.title)|\($0.track.artist)|\($0.isPlaying)" } ?? "idle"
        let lyricsKey: String
        switch lyrics {
        case .synced(let lines):
            lyricsKey = "synced|\(lines.count)|\(lines.first?.time ?? 0)|\(lines.last?.time ?? 0)"
        case .plain(let text):
            lyricsKey = "plain|\(text.count)"
        case .loading:
            lyricsKey = "loading"
        case .instrumental:
            lyricsKey = "instrumental"
        case .notFound:
            lyricsKey = "notFound"
        case .failed(let message):
            lyricsKey = "failed|\(message)"
        case .idle:
            lyricsKey = "idle"
        }
        return "\(track)|\(lyricsKey)|\(lyricsOffset)"
    }

    private func widgetLines() -> [LyricsWidgetState.Line] {
        guard case .synced(let lines) = lyrics else { return [] }
        return lines.map { LyricsWidgetState.Line(time: $0.time, text: $0.text) }
    }

    private func widgetMessage() -> String {
        switch lyrics {
        case .synced:
            return "♪"
        case .plain(let text):
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty ? "Lyrics aren't synced" : line
        case .loading:
            return "Loading lyrics…"
        case .instrumental:
            return "Instrumental"
        case .notFound:
            return "No lyrics found"
        case .failed:
            return "Couldn't load lyrics"
        case .idle:
            return snapshot == nil ? "Nothing playing" : "♪"
        }
    }

    #if os(iOS)
    private func pushLiveActivity() {
        guard liveActivityEnabled, let snapshot else { return }
        let lines = displayLines(at: liveActivityIndex)
        liveActivity.update(LyricsActivityAttributes.ContentState(
            title: snapshot.track.title,
            artist: snapshot.track.artist,
            currentLine: lines.current,
            nextLine: lines.next,
            nextLineFadedIn: false,
            lineIndex: liveActivityIndex ?? -1,
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
    #endif
}
