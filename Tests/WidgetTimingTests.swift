import Foundation

/// Run with Xcode's toolchain:
/// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library \
///   Shared/LyricsWidgetState.swift Lyrics/LyricsData/LRCParser.swift Tests/WidgetTimingTests.swift \
///   -o /tmp/lyrics-widget-timing-tests && /tmp/lyrics-widget-timing-tests
@main
struct WidgetTimingTests {
    static func main() throws {
        let anchor = Date(timeIntervalSince1970: 1_000)
        let lines = [
            LyricsWidgetState.Line(time: 11.52, text: "First line"),
            .init(time: 16.22, text: "Second line"),
            .init(time: 116.70, text: "♪"),
            .init(time: 148.80, text: "After the instrumental"),
            .init(time: 149, text: "Short line"),
            .init(time: 149, text: "Same timestamp"),
        ]
        var state = LyricsWidgetState(
            title: "Timing test", artist: "Test", isPlaying: true, lines: lines,
            anchorPosition: 0, anchorDate: anchor, message: "♪"
        )
        let appLines = lines.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }

        // Compare with the actual in-app selector around every boundary, including long gaps
        // and equal timestamps. The latter must select the last line at that timestamp.
        let positions: [TimeInterval] = [0, 12, 125, 148.79, 200]
            + lines.flatMap { [$0.time - 0.001, $0.time, $0.time + 0.001] }
        for position in positions {
            let now = anchor.addingTimeInterval(position)
            let cue = state.cues(from: now, limit: 1)[0]
            let appIndex = LRCParser.index(in: appLines, at: now.timeIntervalSince(anchor)) ?? -1
            precondition(cue.index == appIndex, "Widget index \(cue.index) differs from app index \(appIndex) at \(position)s")
        }

        // Future entries must use the same boundaries as the app, without advancing lines.
        let cues = state.cues(from: anchor)
        precondition(cues.count == lines.count + 1)
        for cue in cues.dropFirst() {
            precondition(abs(cue.date.timeIntervalSince(anchor) - lines[cue.index].time) < 0.000001)
        }

        // A delayed provider request catches up from the saved clock.
        precondition(state.cues(from: anchor.addingTimeInterval(125))[0].index == 2)

        // A replacement anchor after a seek includes the user's timing offset exactly once.
        state.anchorPosition = 147.8 + 0.5
        let sought = state.cues(from: anchor)
        precondition(sought[0].index == 2)
        precondition(abs(sought[1].date.timeIntervalSince(anchor) - 0.5) < 0.000001)

        // Pausing freezes the same line the app displays, regardless of elapsed wall time.
        state.isPlaying = false
        let paused = state.cues(from: anchor.addingTimeInterval(1_000))
        precondition(paused.count == 1 && paused[0].index == 2)

        state.lines = []
        state.message = "Loading lyrics…"
        precondition(state.cues(from: anchor)[0].current == state.message)
        print("Widget timing checks passed")
    }
}
