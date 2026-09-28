import ActivityKit
import AppIntents
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
                    LyricLinesView(state: context.state, currentSize: 17, nextSize: 15)
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
                KaraokeLinesView(state: state, currentSize: 40, nextSize: 26)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 16)
            // With margins disabled, StandBy clips just above -10pt; that puts the header as close
            // to the system icon's row as it can get without clipping the glyphs.
            .padding(.top, -10)
            .padding(.bottom, 16)
            // StandBy sizes the view to its content and centers it, so claim the full 160pt
            // Live Activity height to keep the header pinned at the top.
            .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 160, alignment: .topLeading)
            .overlay {
                if state.source == "Apple Music" {
                    PlayerTapZones()
                }
            }
            .ignoresSafeArea()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                SongHeader(state: state, font: .caption)
                LyricLinesView(state: state, currentSize: 20, nextSize: 17)
                // Fixed height so the activity doesn't resize whenever a line wraps.
                .frame(height: 76, alignment: .top)
            }
            .padding()
        }
    }
}

/// Invisible buttons over the thirds of the view: previous, play/pause, next.
private struct PlayerTapZones: View {
    var body: some View {
        HStack(spacing: 0) {
            zone(SkipTrackIntent(forward: false))
            zone(TogglePlaybackIntent())
            zone(SkipTrackIntent(forward: true))
        }
    }

    private func zone(_ intent: some AppIntent) -> some View {
        Button(intent: intent) {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StandByHeader: View {
    let state: LyricsActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 0) {
            Text(state.title)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The header shares a row with the system icon StandBy draws at the top center.
            Color.clear.frame(width: 48, height: 1)
            Text(state.artist)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
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

/// Lock Screen and Dynamic Island: the view tree is identical for every update (no `ViewThatFits`, no
/// `if`, no `.id`), so a line change only swaps strings and the text cross-fades in place.
private struct LyricLinesView: View {
    let state: LyricsActivityAttributes.ContentState
    let currentSize: CGFloat
    let nextSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.currentLine)
                .font(.system(size: currentSize, weight: .bold))
                .foregroundStyle(.white)
                // Shrink long lines instead of truncating them with "…".
                .lineLimit(3)
                .minimumScaleFactor(0.5)
                .layoutPriority(1)
            Text(state.nextLine)
                .font(.system(size: nextSize, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// StandBy: lines are identified by their index, so on a line change the next line stays on screen and
/// moves up into the current slot. The new gray preview is drawn invisible for one update, then faded in,
/// so its text doesn't pop. The previous line fades out fast.
/// Line limit and weight stay fixed so the text doesn't reflow mid-move.
private struct KaraokeLinesView: View {
    let state: LyricsActivityAttributes.ContentState
    let currentSize: CGFloat
    let nextSize: CGFloat

    /// How the arriving line grows and brightens, and how the gray preview fades in.
    private static let appear = Animation.smooth(duration: 1.0, extraBounce: 0)
    /// How quickly the previous line is gone.
    private static let depart = Animation.easeOut(duration: 0.2)

    private var lines: [(id: Int, text: String)] {
        var lines = [(id: state.lineIndex, text: state.currentLine)]
        if !state.nextLine.isEmpty { lines.append((id: state.lineIndex + 1, text: state.nextLine)) }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines, id: \.id) { line in
                let isCurrent = line.id == state.lineIndex
                Text(line.text)
                    .font(.system(size: isCurrent ? currentSize : nextSize, weight: .bold))
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : (state.nextLineFadedIn ? 0.5 : 0)))
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .geometryGroup()
                    .animation(Self.appear, value: isCurrent)
                    .animation(Self.appear, value: state.nextLineFadedIn)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(Self.appear),
                        removal: .opacity.animation(Self.depart)
                    ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Self.depart, value: state.lineIndex)
    }
}
