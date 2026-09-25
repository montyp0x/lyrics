import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LyricsWidgetsBundle: WidgetBundle {
    var body: some Widget {
        LyricsLiveActivity()
    }
}

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsActivityAttributes.self) { context in
            LockScreenLyricsView(state: context.state)
                .activityBackgroundTint(.black.opacity(0.75))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .foregroundStyle(.pink)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("\(context.state.title) · \(context.state.artist)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.source)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LyricLinesView(state: context.state, currentFont: .headline, nextFont: .subheadline)
                        .padding(.horizontal, 8)
                }
            } compactLeading: {
                Image(systemName: "music.note")
                    .foregroundStyle(.pink)
            } compactTrailing: {
                Text(context.state.currentLine)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 64)
            } minimal: {
                Image(systemName: "music.note")
                    .foregroundStyle(.pink)
            }
        }
    }
}

private struct LockScreenLyricsView: View {
    let state: LyricsActivityAttributes.ContentState

    @Environment(\.isActivityFullscreen) private var isStandBy

    var body: some View {
        if isStandBy {
            // StandBy may scale this canvas, so fonts start large and shrink to whatever space is available.
            VStack(alignment: .leading, spacing: 12) {
                SongHeader(state: state, font: .headline)
                LyricLinesView(
                    state: state,
                    currentFont: .system(size: 40, weight: .bold),
                    nextFont: .system(size: 26, weight: .semibold),
                    currentLineLimit: 3,
                    nextLineLimit: 2
                )
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SongHeader(state: state, font: .caption)
                LyricLinesView(
                    state: state,
                    currentFont: .title3.bold(),
                    nextFont: .body,
                    currentLineLimit: 2,
                    nextLineLimit: 1
                )
                // Fixed height so the activity doesn't resize whenever a line wraps.
                .frame(height: 76, alignment: .top)
            }
            .padding()
        }
    }
}

private struct SongHeader: View {
    let state: LyricsActivityAttributes.ContentState
    let font: Font

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                .foregroundStyle(.pink)
            Text("\(state.title) · \(state.artist)")
                .lineLimit(1)
            Spacer()
            Text(state.source)
        }
        .font(font)
        .foregroundStyle(.white.opacity(0.7))
    }
}

private struct LyricLinesView: View {
    let state: LyricsActivityAttributes.ContentState
    let currentFont: Font
    let nextFont: Font
    var currentLineLimit = 2
    var nextLineLimit = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.currentLine)
                .font(currentFont)
                .foregroundStyle(.white)
                .lineLimit(currentLineLimit)
                .minimumScaleFactor(0.4)
                .layoutPriority(1)
                .id(state.currentLine)
                .transition(.push(from: .bottom))
            if !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(nextFont)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(nextLineLimit)
                    .minimumScaleFactor(0.5)
                    .id("next-\(state.nextLine)")
                    .transition(.push(from: .bottom))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
