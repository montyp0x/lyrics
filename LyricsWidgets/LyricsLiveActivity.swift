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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(.pink)
                Text("\(state.title) · \(state.artist)")
                    .lineLimit(1)
                Spacer()
                Text(state.source)
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.7))

            LyricLinesView(state: state, currentFont: .title3.bold(), nextFont: .body)
        }
        .padding()
    }
}

private struct LyricLinesView: View {
    let state: LyricsActivityAttributes.ContentState
    let currentFont: Font
    let nextFont: Font

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.currentLine)
                .font(currentFont)
                .foregroundStyle(.white)
                .lineLimit(2)
                .id(state.currentLine)
                .transition(.push(from: .bottom))
            if !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(nextFont)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .id("next-\(state.nextLine)")
                    .transition(.push(from: .bottom))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
