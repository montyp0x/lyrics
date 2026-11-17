import CryptoKit
import Foundation

/// Lyrics lookups saved in Caches, one small JSON file per track, so replays load instantly and work offline.
/// Synced lyrics are kept until the system purges Caches. Anything else expires after `unsyncedLifetime`,
/// because LRCLIB and Apple Music add synced lyrics over time.
struct LyricsDiskCache {
    var directory: URL
    var unsyncedLifetime: TimeInterval = 3 * 24 * 60 * 60

    static let shared = LyricsDiskCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyrics", isDirectory: true)
    )

    private struct Entry: Codable {
        var kind: Kind
        var times: [TimeInterval]?
        var texts: [String]?
        var plain: String?
        var savedAt: Date

        enum Kind: String, Codable { case synced, plain, instrumental, notFound }
    }

    func load(_ track: Track, now: Date = .now) -> LyricsLookup? {
        guard let data = try? Data(contentsOf: fileURL(for: track)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        if entry.kind != .synced, now.timeIntervalSince(entry.savedAt) > unsyncedLifetime { return nil }
        switch entry.kind {
        case .synced:
            guard let times = entry.times, let texts = entry.texts, times.count == texts.count, !times.isEmpty else {
                return nil
            }
            return .synced(zip(times, texts).enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) })
        case .plain:
            return entry.plain.map(LyricsLookup.plain)
        case .instrumental:
            return .instrumental
        case .notFound:
            return .notFound
        }
    }

    func save(_ lookup: LyricsLookup, for track: Track, now: Date = .now) {
        var entry = Entry(kind: .notFound, savedAt: now)
        switch lookup {
        case .synced(let lines):
            entry.kind = .synced
            entry.times = lines.map(\.time)
            entry.texts = lines.map(\.text)
        case .plain(let text):
            entry.kind = .plain
            entry.plain = text
        case .instrumental:
            entry.kind = .instrumental
        case .notFound:
            entry.kind = .notFound
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: fileURL(for: track), options: .atomic)
        } catch {
            // A cache miss next time is fine; Caches is unreadable before the first unlock after boot.
        }
    }

    /// Drops everything except synced lyrics, e.g. after a new Apple Music token makes more songs available.
    func removeUnsynced() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            let entry = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) }
            if entry?.kind != .synced { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func fileURL(for track: Track) -> URL {
        let key = [
            track.title, track.artist, track.album,
            String(Int(track.duration.rounded())), track.appleMusicID ?? "",
        ].joined(separator: "\n")
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension("json")
    }
}
