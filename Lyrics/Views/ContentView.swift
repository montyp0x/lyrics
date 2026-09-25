import SwiftUI

struct ContentView: View {
    @Environment(LyricsEngine.self) private var engine
    @State private var showingSettings = false

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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }

    private var emptyHint: String {
        if !engine.appleMusic.isAuthorized && !engine.spotifyAuth.isConnected {
            return "Connect Apple Music or Spotify in Settings."
        }
        return "Play a song in Apple Music or Spotify."
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
