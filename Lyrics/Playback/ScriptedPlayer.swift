#if os(macOS)
import AppKit
import Foundation

/// Now-playing state from the Music and Spotify Mac apps.
///
/// `MPMusicPlayerController` is unavailable on macOS, and Spotify's Web API can't see the desktop app
/// without a developer client. AppleScript can, once the user allows Automation.
@MainActor
enum ScriptedPlayer {
    case music
    case spotify

    /// Set when macOS has not allowed Lyrics to control Music or Spotify.
    static var accessError: String? {
        guard musicDenied || spotifyDenied else { return nil }
        return "Allow Lyrics to control Music and Spotify in System Settings → Privacy & Security → Automation."
    }
    private static var musicDenied = false
    private static var spotifyDenied = false

    func snapshot() -> PlaybackSnapshot? {
        switch self {
        case .music:
            let (snapshot, error) = Self.musicScript.execute(source: .appleMusic)
            Self.musicDenied = error?.localizedCaseInsensitiveContains("not authorized") == true
            return snapshot
        case .spotify:
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil else { return nil }
            let (snapshot, error) = Self.spotifyScript.execute(source: .spotify)
            Self.spotifyDenied = error?.localizedCaseInsensitiveContains("not authorized") == true
            return snapshot
        }
    }

    private static let musicScript = CompiledScript(source: """
    if application "Music" is not running then return ""
    tell application "Music"
        if player state is stopped then return ""
        try
            set t to current track
            set trackName to name of t
            set trackArtist to artist of t
            set trackAlbum to album of t
            set trackDuration to duration of t
            set pos to player position
            if player state is playing then
                set stateName to "playing"
            else
                set stateName to "paused"
            end if
        on error
            return ""
        end try
    end tell
    set durMs to round (trackDuration * 1000)
    set posMs to round (pos * 1000)
    return {trackName, trackArtist, trackAlbum, durMs, posMs, stateName}
    """)

    /// Spotify's `duration` is already milliseconds. `player position` is seconds, same as Music.
    private static let spotifyScript = CompiledScript(source: """
    if application "Spotify" is not running then return ""
    tell application "Spotify"
        if player state is stopped then return ""
        try
            set trackName to name of current track
            set trackArtist to artist of current track
            set trackAlbum to album of current track
            set trackDuration to duration of current track
            set pos to player position
            if player state is playing then
                set stateName to "playing"
            else
                set stateName to "paused"
            end if
        on error
            return ""
        end try
    end tell
    set posMs to round (pos * 1000)
    return {trackName, trackArtist, trackAlbum, trackDuration, posMs, stateName}
    """)
}

@MainActor
private final class CompiledScript {
    private let source: String
    private var script: NSAppleScript?
    private var compileFailed = false
    private var lastError: String?

    init(source: String) {
        self.source = source
    }

    func execute(source player: MusicSource) -> (PlaybackSnapshot?, String?) {
        guard let script = compiled() else { return (nil, nil) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? String(describing: error)
            if message != lastError {
                lastError = message
                DiagnosticsLog.write("applescript \(player.rawValue): \(message)")
            }
            return (nil, message)
        }
        lastError = nil
        guard result.numberOfItems >= 6, let title = result.atIndex(1)?.stringValue, !title.isEmpty else { return (nil, nil) }
        let durationMs = result.atIndex(4)?.doubleValue ?? 0
        let positionMs = max(0, result.atIndex(5)?.doubleValue ?? 0)
        let snapshot = PlaybackSnapshot(
            source: player,
            track: Track(
                title: title,
                artist: result.atIndex(2)?.stringValue ?? "",
                album: result.atIndex(3)?.stringValue ?? "",
                duration: durationMs / 1000
            ),
            position: positionMs / 1000,
            isPlaying: result.atIndex(6)?.stringValue == "playing",
            capturedAt: .now
        )
        return (snapshot, nil)
    }

    private func compiled() -> NSAppleScript? {
        if let script { return script }
        guard !compileFailed else { return nil }
        guard let script = NSAppleScript(source: source) else {
            compileFailed = true
            return nil
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            compileFailed = true
            let message = error?[NSAppleScript.errorMessage] as? String ?? "compile failed"
            DiagnosticsLog.write("applescript compile: \(message)")
            return nil
        }
        self.script = script
        return script
    }
}
#endif
