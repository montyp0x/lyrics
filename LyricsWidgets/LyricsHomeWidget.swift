import AppIntents
import SwiftUI
import WidgetKit

struct LyricsHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: LyricsWidgetState.kind, provider: HomeProvider()) { entry in
            HomeWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color.black }
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Lyrics")
        .description("The line that's playing now.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct HomeProvider: TimelineProvider {
    func placeholder(in context: Context) -> HomeEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (HomeEntry) -> Void) {
        completion(HomeEntry.current() ?? .placeholder)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<HomeEntry>) -> Void) {
        guard let state = LyricsWidgetStore.load() else {
            completion(Timeline(entries: [.placeholder], policy: .never))
            return
        }
        let entries = state.cues(from: .now).map { HomeEntry(cue: $0, state: state) }
        let policy: TimelineReloadPolicy = state.isPlaying && entries.count > 1
            ? .after(entries.last!.date.addingTimeInterval(0.5))
            : .never
        completion(Timeline(entries: entries.isEmpty ? [.placeholder] : entries, policy: policy))
    }
}

private struct HomeEntry: TimelineEntry {
    var date: Date
    var title: String
    var artist: String
    var source: String
    var lineIndex: Int
    var currentLine: String
    var nextLine: String
    var isPlaying: Bool

    static let placeholder = HomeEntry(
        date: .now,
        title: "Lyrics",
        artist: "Now playing",
        source: "",
        lineIndex: 0,
        currentLine: "The current line",
        nextLine: "The next line",
        isPlaying: true
    )

    init(cue: LyricsWidgetState.Cue, state: LyricsWidgetState) {
        date = cue.date
        title = state.title
        artist = state.artist
        source = state.source
        lineIndex = cue.index
        currentLine = cue.current
        nextLine = cue.following.first ?? ""
        isPlaying = state.isPlaying
    }

    init(date: Date, title: String, artist: String, source: String, lineIndex: Int, currentLine: String, nextLine: String, isPlaying: Bool) {
        self.date = date
        self.title = title
        self.artist = artist
        self.source = source
        self.lineIndex = lineIndex
        self.currentLine = currentLine
        self.nextLine = nextLine
        self.isPlaying = isPlaying
    }

    static func current() -> HomeEntry? {
        guard let state = LyricsWidgetStore.load(), let cue = state.cues(from: .now, limit: 1).first else { return nil }
        return HomeEntry(cue: cue, state: state)
    }
}

private struct HomeWidgetView: View {
    var entry: HomeEntry

    var body: some View {
        GeometryReader { geo in
            let metrics = HomeMetrics(size: geo.size)
            VStack(spacing: metrics.spacing) {
                VStack(alignment: .leading, spacing: metrics.spacing) {
                    if !entry.title.isEmpty {
                        HStack(spacing: 8) {
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
                    HomeLines(
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
                if metrics.showsControls, entry.source == "appleMusic" {
                    HStack(spacing: 0) {
                        control("backward.fill", intent: SkipTrackIntent(forward: false), size: metrics.control)
                        control(entry.isPlaying ? "pause.fill" : "play.fill", intent: TogglePlaybackIntent(), size: metrics.control)
                        control("forward.fill", intent: SkipTrackIntent(forward: true), size: metrics.control)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.9))
                }
            }
            .padding(metrics.padding)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private func control(_ systemImage: String, intent: some AppIntent, size: CGFloat) -> some View {
        Button(intent: intent) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: size + 8)
                .contentShape(Rectangle())
        }
    }
}

private struct HomeMetrics {
    var padding: CGFloat
    var spacing: CGFloat
    var header: CGFloat
    var current: CGFloat
    var next: CGFloat
    var control: CGFloat
    var showsControls: Bool

    init(size: CGSize) {
        showsControls = size.width > 250 || size.height > 220
        padding = size.height < 180 ? 12 : 16
        let contentHeight = max(size.height - padding * 2, 1)
        spacing = max(6, contentHeight * 0.04)
        header = min(max(contentHeight * 0.1, 12), 20)
        let controls = showsControls ? contentHeight * 0.18 : 0
        let stage = max(contentHeight - controls - header, 1)
        current = min(max(stage * 0.28, 17), size.width * 0.09, 40)
        next = current * 0.65
        control = min(max(size.height * 0.08, 14), 22)
    }
}

private struct HomeLines: View {
    var lineIndex: Int
    var currentLine: String
    var nextLine: String
    var currentSize: CGFloat
    var nextSize: CGFloat

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
                    .lineLimit(isCurrent ? 4 : 2)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
