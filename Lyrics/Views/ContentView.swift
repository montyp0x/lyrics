import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @Environment(LyricsEngine.self) private var engine
    #if os(iOS)
    @State private var showingSettings = false
    #endif

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let snapshot = engine.snapshot {
                    NowPlayingHeader(snapshot: snapshot)
                        .padding()
                    Divider()
                    LyricsBody()
                } else {
                    ContentUnavailableView(
                        "Nothing playing",
                        systemImage: "music.note",
                        description: Text(emptyHint)
                    )
                }
            }
            .navigationTitle("Lyrics")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(macOS)
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                #else
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                #endif
            }
            #if os(iOS)
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            #else
            .background(WindowLevelAccessor(floating: engine.floatWindow))
            .frame(minWidth: 380, minHeight: 520)
            #endif
        }
    }

    private var emptyHint: String {
        #if os(macOS)
        if let playbackAccessError = engine.playbackAccessError { return playbackAccessError }
        return "Play a song in Music or Spotify."
        #else
        if !engine.appleMusic.isAuthorized && !engine.spotifyAuth.isConnected {
            return "Connect Apple Music or Spotify in Settings."
        }
        return "Play a song in Apple Music or Spotify."
        #endif
    }
}

private struct NowPlayingHeader: View {
    let snapshot: PlaybackSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: snapshot.isPlaying ? "waveform" : "pause.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.track.title).font(.headline).lineLimit(1)
                Text(snapshot.track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(snapshot.source.displayName)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
    }
}

private struct LyricsBody: View {
    @Environment(LyricsEngine.self) private var engine

    var body: some View {
        switch engine.lyrics {
        case .synced(let lines):
            SyncedLyricsView(lines: lines, currentIndex: engine.currentIndex)
        case .plain(let text):
            ScrollView {
                Text(text)
                    .font(.title3)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .loading:
            ProgressView().frame(maxHeight: .infinity)
        case .instrumental:
            ContentUnavailableView("Instrumental", systemImage: "pianokeys")
        case .notFound:
            ContentUnavailableView("No lyrics found", systemImage: "text.badge.xmark")
        case .failed(let message):
            ContentUnavailableView("Couldn't load lyrics", systemImage: "wifi.exclamationmark", description: Text(message))
        case .idle:
            Spacer()
        }
    }
}

private struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let currentIndex: Int?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title2.bold())
                            .foregroundStyle(line.id == currentIndex ? .primary : .tertiary)
                            .id(line.id)
                    }
                }
                .padding()
                .padding(.vertical, 200)
            }
            .onChange(of: currentIndex) { _, index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(index, anchor: .center)
                }
            }
        }
    }
}

#if os(macOS)
struct MacMenuBarLabel: View {
    var snapshot: PlaybackSnapshot?
    var lyrics: LyricsState
    var currentIndex: Int?

    var body: some View {
        let line = menuBarLine
        if line.isEmpty {
            Image(systemName: "music.note")
        } else {
            Text(line)
        }
    }

    /// Kept short so a long lyric doesn't take over the menu bar.
    private var menuBarLine: String {
        let line = LyricLines.current(lyrics: lyrics, index: currentIndex)
        guard !line.isEmpty else { return snapshot?.track.title ?? "" }
        if line.count > 42 { return String(line.prefix(40)) + "…" }
        return line
    }
}

struct MacMenuBarView: View {
    @Environment(LyricsEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snapshot = engine.snapshot {
                HStack {
                    Text(snapshot.track.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(snapshot.source.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(snapshot.track.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(LyricLines.current(lyrics: engine.lyrics, index: engine.currentIndex))
                    .font(.title3.bold())
                    .fixedSize(horizontal: false, vertical: true)
                let next = LyricLines.next(lyrics: engine.lyrics, index: engine.currentIndex)
                if !next.isEmpty {
                    Text(next)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Nothing playing").font(.headline)
                Text(engine.playbackAccessError ?? "Play a song in Music or Spotify.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Lyrics") { openWindow(id: "main") }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 320)
    }
}

private enum LyricLines {
    static func current(lyrics: LyricsState, index: Int?) -> String {
        switch lyrics {
        case .synced(let lines):
            guard let index, lines.indices.contains(index) else { return "" }
            let text = lines[index].text
            return text.isEmpty ? "♪" : text
        case .loading: return "Loading lyrics…"
        case .plain: return "Lyrics aren't synced"
        case .instrumental: return "Instrumental"
        case .notFound: return "No lyrics found"
        case .failed: return "Couldn't load lyrics"
        case .idle: return ""
        }
    }

    static func next(lyrics: LyricsState, index: Int?) -> String {
        guard case .synced(let lines) = lyrics, let index else { return "" }
        let next = index + 1
        guard lines.indices.contains(next) else { return "" }
        return lines[next].text
    }
}

/// SwiftUI has no window-level modifier that goes back to macOS 14, so a hidden view sets it.
private struct WindowLevelAccessor: NSViewRepresentable {
    var floating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let level: NSWindow.Level = floating ? .floating : .normal
        if let window = view.window {
            window.level = level
        } else {
            DispatchQueue.main.async { [weak view] in
                view?.window?.level = level
            }
        }
    }
}
#endif
