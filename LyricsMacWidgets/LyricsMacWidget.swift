import SwiftUI
import WidgetKit

@main
struct LyricsMacWidgetBundle: WidgetBundle {
    var body: some Widget {
        LyricsMacWidget()
    }
}

struct LyricsMacWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LyricsWidgetState.kind, provider: Provider()) { entry in
            LyricsWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Lyrics")
        .description("The line that's playing now.")
        .supportedFamilies(Self.families)
    }

    /// Right-click the widget on the desktop to pick one of these. Lyrics scale with the size.
    private static var families: [WidgetFamily] {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        if #available(macOS 27, *) {
            families.append(.systemExtraLargePortrait)
        }
        return families
    }
}

private struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry.current() ?? .placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        guard let state = LyricsWidgetStore.load() else {
            completion(Timeline(entries: [.placeholder], policy: .never))
            return
        }
        let entries = state.cues(from: .now).map { Entry(cue: $0, state: state) }
        let policy: TimelineReloadPolicy = state.isPlaying && entries.count > 1
            ? .after(entries.last!.date.addingTimeInterval(0.5))
            : .never
        completion(Timeline(entries: entries.isEmpty ? [.placeholder] : entries, policy: policy))
    }
}

private struct Entry: TimelineEntry {
    var date: Date
    var title: String
    var artist: String
    var lineIndex: Int
    var currentLine: String
    var nextLine: String
    var isPlaying: Bool

    static let placeholder = Entry(
        date: .now,
        title: "Lyrics",
        artist: "Now playing",
        lineIndex: 0,
        currentLine: "The current line",
        nextLine: "The next line",
        isPlaying: true
    )

    init(cue: LyricsWidgetState.Cue, state: LyricsWidgetState) {
        date = cue.date
        title = state.title
        artist = state.artist
        lineIndex = cue.index
        currentLine = cue.current
        nextLine = cue.following.first ?? ""
        isPlaying = state.isPlaying
    }

    init(date: Date, title: String, artist: String, lineIndex: Int, currentLine: String, nextLine: String, isPlaying: Bool) {
        self.date = date
        self.title = title
        self.artist = artist
        self.lineIndex = lineIndex
        self.currentLine = currentLine
        self.nextLine = nextLine
        self.isPlaying = isPlaying
    }

    static func current() -> Entry? {
        guard let state = LyricsWidgetStore.load(), let cue = state.cues(from: .now, limit: 1).first else { return nil }
        return Entry(cue: cue, state: state)
    }
}

/// Same arrangement as StandBy karaoke: title and artist on one row, the current line large and white,
/// the next line smaller and dim. Lines are keyed by index so a line change moves "next" up into "current".
private struct LyricsWidgetView: View {
    var entry: Entry

    var body: some View {
        GeometryReader { geo in
            let metrics = Metrics(size: geo.size)
            VStack(spacing: metrics.blockSpacing) {
                VStack(alignment: .leading, spacing: metrics.blockSpacing) {
                    if !entry.title.isEmpty {
                        HStack(spacing: 12) {
                            Text(entry.title)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(entry.artist)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .font(.system(size: metrics.header, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    }
                    KaraokeLines(
                        lineIndex: entry.lineIndex,
                        currentLine: entry.currentLine,
                        nextLine: entry.nextLine,
                        currentSize: metrics.current,
                        nextSize: metrics.next
                    )
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .widgetURL(URL(string: "lyrics-app://open"))
                HStack(spacing: 0) {
                    playbackButton("backward.fill", command: .previous, size: metrics.control)
                    playbackButton(entry.isPlaying ? "pause.fill" : "play.fill", command: .toggle, size: metrics.control)
                    playbackButton("forward.fill", command: .next, size: metrics.control)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.9))
            }
            .padding(metrics.padding)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private func playbackButton(_ systemImage: String, command: MacPlaybackCommand, size: CGFloat) -> some View {
        Button(intent: MacPlaybackIntent(command: command)) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: size + 8)
                .contentShape(Rectangle())
        }
    }
}

/// StandBy is 40 / 26 in a short stage. Larger desktop sizes get the same proportions, so picking
/// a bigger widget in the system size menu actually enlarges the lines.
private struct Metrics {
    var padding: CGFloat
    var blockSpacing: CGFloat
    var header: CGFloat
    var current: CGFloat
    var next: CGFloat
    var control: CGFloat

    init(size: CGSize) {
        padding = size.height < 200 ? 12 : 18
        let contentHeight = max(size.height - padding * 2, 1)
        blockSpacing = max(8, contentHeight * 0.05)
        header = min(max(contentHeight * 0.11, 13), 34)
        // Height wants a big line; width keeps a long lyric from starting larger than it can fit.
        // Leave a row at the bottom for previous / pause / next.
        let stage = max(contentHeight - size.height * 0.16, 1)
        current = min(max(stage * 0.34, 20), size.width * 0.13, 84)
        next = current * 0.65
        control = min(max(size.height * 0.09, 14), 26)
    }
}

private struct KaraokeLines: View {
    var lineIndex: Int
    var currentLine: String
    var nextLine: String
    var currentSize: CGFloat
    var nextSize: CGFloat

    /// How the arriving line grows and brightens.
    private static let appear = Animation.smooth(duration: 1.0, extraBounce: 0)
    /// How quickly the previous line is gone.
    private static let depart = Animation.easeOut(duration: 0.2)

    private var lines: [(id: Int, text: String)] {
        var lines = [(id: lineIndex, text: currentLine)]
        if !nextLine.isEmpty { lines.append((id: lineIndex + 1, text: nextLine)) }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.id) { line in
                let isCurrent = line.id == lineIndex
                Text(line.text)
                    .font(.system(size: isCurrent ? currentSize : nextSize, weight: .bold))
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.5))
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .geometryGroup()
                    .animation(Self.appear, value: isCurrent)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(Self.appear),
                        removal: .opacity.animation(Self.depart)
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Self.depart, value: lineIndex)
    }
}
