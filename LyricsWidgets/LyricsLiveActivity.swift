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
                    LyricLinesView(state: context.state, sizes: [
                        .init(current: 17, next: 15),
                        .init(current: 15, next: 13),
                    ])
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
        .contentMarginsDisabled()
    }
}

private struct LockScreenLyricsView: View {
    let state: LyricsActivityAttributes.ContentState

    @Environment(\.isActivityFullscreen) private var isStandBy

    var body: some View {
        if isStandBy {
            VStack(alignment: .leading, spacing: 12) {
                StandByHeader(state: state)
                LyricLinesView(state: state, sizes: [
                    .init(current: 40, next: 26),
                    .init(current: 34, next: 23),
                    .init(current: 28, next: 20),
                    .init(current: 24, next: 18),
                    .init(current: 20, next: 16),
                ])
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 16)
            // With margins disabled, StandBy clips about 16pt above this view's top edge; -12pt puts
            // the header level with the system icon without clipping it.
            .padding(.top, -12)
            .padding(.bottom, 16)
            // StandBy sizes the view to its content and centers it, so claim the full 160pt
            // Live Activity height to keep the header pinned at the top.
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160, alignment: .topLeading)
            .ignoresSafeArea()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SongHeader(state: state, font: .caption)
                LyricLinesView(state: state, sizes: [
                    .init(current: 20, next: 17),
                    .init(current: 17, next: 15),
                    .init(current: 15, next: 13),
                ])
                // Fixed height so the activity doesn't resize whenever a line wraps.
                .frame(height: 76, alignment: .top)
            }
            .padding()
        }
    }
}

private struct StandByHeader: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 0) {
            Text(state.title)
            Spacer(minLength: 24)
            Text(state.artist)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .font(.headline)
        .foregroundStyle(.white.opacity(0.7))
    }
}

private struct SongHeader: View {
    let state: LyricsActivityAttributes.ContentState
    let font: Font

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                .foregroundStyle(.pink)
            Text(state.title)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text(state.artist)
                .lineLimit(1)
        }
        .font(font)
        .foregroundStyle(.white.opacity(0.7))
    }
}

/// Renders the current and next line at the largest size that fits without truncation.
private struct LyricLinesView: View {
    struct Sizes {
        let current: CGFloat
        let next: CGFloat
    }

    let state: LyricsActivityAttributes.ContentState
    /// Largest first. The last entry is the fallback and may still shrink or truncate.
    let sizes: [Sizes]

    var body: some View {
        ViewThatFits(in: .vertical) {
            ForEach(sizes.indices, id: \.self) { index in
                lines(sizes[index], isFallback: index == sizes.count - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lines(_ size: Sizes, isFallback: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.currentLine)
                .font(.system(size: size.current, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(isFallback ? 3 : nil)
                .minimumScaleFactor(isFallback ? 0.6 : 1)
                .layoutPriority(1)
                .id(state.currentLine)
                .transition(.push(from: .bottom))
            if !state.nextLine.isEmpty {
                Text(state.nextLine)
                    .font(.system(size: size.next, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(isFallback ? 2 : nil)
                    .minimumScaleFactor(isFallback ? 0.6 : 1)
                    .id("next-\(state.nextLine)")
                    .transition(.push(from: .bottom))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
