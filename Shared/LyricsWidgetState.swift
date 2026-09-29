import Foundation

/// Darwin notification posted after a widget or Live Activity playback command, so the app polls immediately.
let playerCommandNotification = "com.ramych.lyrics.playerCommand"

/// Snapshot the app writes for the home-screen widget.
///
/// The widget can't be pushed on every line, so this is a clock: `anchorPosition` was the playback
/// position at `anchorDate`. While `isPlaying` is true the widget schedules one timeline entry per
/// remaining line and WidgetKit advances it. A seek, pause, or track change writes a new snapshot.
struct LyricsWidgetState: Codable, Equatable {
    struct Line: Codable, Equatable {
        var time: TimeInterval
        var text: String
    }

    /// One moment on the widget timeline.
    struct Cue {
        var date: Date
        /// Index of `current` in `lines`, or -1 before the first line. The widget keys lines by this so the
        /// next line can move up into the current slot, the way StandBy karaoke does.
        var index: Int
        var current: String
        var following: [String]
    }

    var title: String
    var artist: String
    /// `appleMusic` or `spotify`, matching `MusicSource`. The widget's buttons control this app.
    var source: String = ""
    var isPlaying: Bool
    var lines: [Line]
    /// Playback position, in seconds, including the user's timing offset.
    var anchorPosition: TimeInterval
    var anchorDate: Date
    /// Shown when there are no synced lines ("Nothing playing", "Loading lyrics…", …).
    var message: String

    static let kind = "LyricsMacWidget"

    func cues(from now: Date, limit: Int = 80) -> [Cue] {
        let played = isPlaying ? anchorPosition + now.timeIntervalSince(anchorDate) : anchorPosition
        guard !lines.isEmpty else {
            return [Cue(date: now, index: -1, current: message, following: [])]
        }
        // 0.65s early was about a line late, and a whole line early was too fast. Three quarters of
        // the gap lands between those.
        let index = displayedIndex(at: played)
        var cues = [Cue(date: now, index: index, current: text(at: index), following: following(after: index))]
        guard isPlaying else { return cues }
        var nextIndex = index + 1
        while nextIndex < lines.count, cues.count < limit {
            let date = anchorDate.addingTimeInterval(lines[nextIndex].time - lead(before: nextIndex) - anchorPosition)
            if date > now {
                cues.append(Cue(date: date, index: nextIndex, current: text(at: nextIndex), following: following(after: nextIndex)))
            }
            nextIndex += 1
        }
        return cues
    }

    /// How early to show the line at `index`: three quarters of the gap from the previous line,
    /// never less than the iPhone's 0.65s and never a whole line.
    private func lead(before index: Int) -> TimeInterval {
        let gap: TimeInterval
        if index > 0 {
            gap = lines[index].time - lines[index - 1].time
        } else if lines.count > 1 {
            gap = lines[1].time - lines[0].time
        } else {
            gap = 4
        }
        let safeGap = max(gap, 0.8)
        return min(max(safeGap * 0.75, 0.65), safeGap - 0.2)
    }

    private func displayedIndex(at played: TimeInterval) -> Int {
        var shown = -1
        for index in lines.indices {
            if lines[index].time - lead(before: index) <= played {
                shown = index
            } else {
                break
            }
        }
        return shown
    }

    private func text(at index: Int) -> String {
        guard lines.indices.contains(index) else { return "♪" }
        return display(lines[index].text)
    }

    private func following(after index: Int) -> [String] {
        (1...6).compactMap { offset in
            let next = index + offset
            guard lines.indices.contains(next) else { return nil }
            return display(lines[next].text)
        }
    }

    private func display(_ text: String) -> String {
        text.isEmpty ? "♪" : text
    }
}

enum LyricsWidgetStore {
    static let appGroupID = "group.com.ramych.lyrics"

    /// iOS shares the file through the app group. macOS writes the real home directory instead:
    /// app groups aren't writable with this development signing setup, and the widget is allowed
    /// to read that directory by a sandbox exception.
    static var fileURL: URL {
        #if os(iOS)
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return URL(fileURLWithPath: "/private/tmp/lyrics-widget-state-unavailable.json")
        }
        return directory.appendingPathComponent("widget-state.json")
        #else
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Lyrics", isDirectory: true)
            .appendingPathComponent("widget-state.json")
        #endif
    }

    static func save(_ state: LyricsWidgetState) throws {
        #if os(iOS)
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: "app group \(appGroupID) is unavailable",
            ])
        }
        #endif
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    static func load() -> LyricsWidgetState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(LyricsWidgetState.self, from: data)
    }
}
