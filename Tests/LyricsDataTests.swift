import Foundation

/// Parsers, title cleanup, catalog matching, and the disk cache. Run with Xcode's toolchain:
/// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc -parse-as-library \
///   Lyrics/Playback/Models.swift Lyrics/LyricsData/LyricsLookup.swift Lyrics/LyricsData/LRCParser.swift \
///   Lyrics/LyricsData/TTMLParser.swift Lyrics/LyricsData/LRCLibClient.swift Lyrics/LyricsData/CatalogMatcher.swift \
///   Lyrics/LyricsData/LyricsDiskCache.swift Tests/LyricsDataTests.swift \
///   -o /tmp/lyrics-data-tests && /tmp/lyrics-data-tests
@main
struct LyricsDataTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String, line: Int = #line) {
        if !condition {
            failures += 1
            print("FAIL line \(line): \(message)")
        }
    }

    static func main() throws {
        lrc()
        ttml()
        titlesAndArtists()
        catalogMatching()
        try diskCache()
        if failures > 0 {
            print("\(failures) failure(s)")
            exit(1)
        }
        print("All lyrics data tests passed")
    }

    static func lrc() {
        let lines = LRCParser.parse("""
        [ar:Someone]
        [00:12.50]Second
        [00:01.00][00:20.00]Repeated
        [01:02.25]
        """)
        check(lines.map(\.time) == [1, 12.5, 20, 62.25], "sorted times, got \(lines.map(\.time))")
        check(lines.map(\.text) == ["Repeated", "Second", "Repeated", ""], "texts, got \(lines.map(\.text))")
        check(lines.map(\.id) == [0, 1, 2, 3], "ids follow sorted order")

        let shifted = LRCParser.parse("[offset:+500]\n[00:10.00]A\n[00:00.20]B")
        check(shifted.map(\.time) == [0, 9.5], "positive offset shows lines earlier, clamped at 0, got \(shifted.map(\.time))")
        let later = LRCParser.parse("[offset:-250]\n[00:10.00]A")
        check(later.first?.time == 10.25, "negative offset shows lines later")

        check(LRCParser.index(in: lines, at: 0.5) == nil, "nothing before the first line")
        check(LRCParser.index(in: lines, at: 12.5) == 1, "a line starts exactly at its time")
        check(LRCParser.index(in: lines, at: 999) == 3, "last line after the end")
    }

    static func ttml() {
        let ttml = """
        <tt><body><div>
        <p begin="1:02.5" end="1:04"><span begin="1:02.5">Rock</span> <span>&amp; roll</span></p>
        <p begin="10.25s">It&#39;s &#x2014; &quot;fine&quot; &amp;#39;</p>
        <p begin="20">Lead<span ttm:role="x-bg">(echo)</span></p>
        </div></body></tt>
        """
        guard case .synced(let lines) = TTMLParser.parse(ttml) else {
            check(false, "timed TTML parses as synced")
            return
        }
        check(lines.map(\.time) == [10.25, 20, 62.5], "TTML times, got \(lines.map(\.time))")
        check(lines[0].text == "It's \u{2014} \"fine\" &#39;", "entities decoded once, got \(lines[0].text)")
        check(lines[1].text == "Lead (echo)", "background vocals get a space, got \(lines[1].text)")
        check(lines[2].text == "Rock & roll", "spans stripped, got \(lines[2].text)")

        let untimed = TTMLParser.parse(#"<tt itunes:timing="None"><p>One</p><p>Two</p></tt>"#)
        check(untimed == .plain("One\nTwo"), "untimed TTML is plain text")
        check(TTMLParser.parse("<tt></tt>") == .notFound, "empty TTML is not found")
    }

    static func titlesAndArtists() {
        check(LRCLibClient.cleanTitle("Song (feat. X)") == "Song", "feat. stripped")
        check(LRCLibClient.cleanTitle("Song - 2011 Remaster") == "Song", "remaster suffix stripped")
        check(LRCLibClient.cleanTitle("(feat. X)") == "(feat. X)", "never cleaned down to nothing")
        let track = Track(title: "T", artist: "Big Baby Tape & Kizaru", album: "", duration: 0)
        check(track.primaryArtist == "Big Baby Tape", "primary artist, got \(track.primaryArtist)")
    }

    static func catalogMatching() {
        let track = Track(title: "Song (feat. Guest)", artist: "Main, Guest", album: "", duration: 200)
        let cover = CatalogMatcher.Candidate(id: "cover", title: "Song", artist: "Cover Band", durationInMillis: 201_500)
        let original = CatalogMatcher.Candidate(id: "orig", title: "Song", artist: "Main", durationInMillis: 202_000)
        check(CatalogMatcher.bestMatch(for: track, in: [cover, original])?.id == "orig",
              "same artist wins over a closer-duration cover")
        check(CatalogMatcher.bestMatch(for: track, in: [cover]) == nil,
              "a different artist needs the duration within 1 s")

        let transliterated = CatalogMatcher.Candidate(id: "cyr", title: "Song", artist: "Мэйн", durationInMillis: 200_400)
        check(CatalogMatcher.bestMatch(for: track, in: [transliterated])?.id == "cyr",
              "artist spelled differently still matches on a near-exact duration")

        let accents = Track(title: "Cafe", artist: "Beyonce", album: "", duration: 180)
        let accented = CatalogMatcher.Candidate(id: "acc", title: "Café", artist: "Beyoncé", durationInMillis: 182_000)
        check(CatalogMatcher.bestMatch(for: accents, in: [accented])?.id == "acc", "diacritics ignored")

        let noDuration = Track(title: "Song", artist: "Main", album: "", duration: 0)
        check(CatalogMatcher.bestMatch(for: noDuration, in: [cover]) == nil, "no duration and no artist match: no match")
        check(CatalogMatcher.bestMatch(for: noDuration, in: [original])?.id == "orig", "no duration, same artist: match")
    }

    static func diskCache() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lyrics-cache-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LyricsDiskCache(directory: directory)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let synced = Track(title: "A", artist: "B", album: "C", duration: 100)
        let missing = Track(title: "Missing", artist: "B", album: "C", duration: 100)
        let lines = [LyricLine(id: 0, time: 1.5, text: "one"), LyricLine(id: 1, time: 3, text: "two")]

        check(cache.load(synced) == nil, "empty cache misses")
        cache.save(.synced(lines), for: synced, now: now)
        cache.save(.notFound, for: missing, now: now)
        check(cache.load(synced, now: now) == .synced(lines), "synced round trip")
        check(cache.load(missing, now: now.addingTimeInterval(60)) == .notFound, "fresh not-found is kept")

        let muchLater = now.addingTimeInterval(30 * 24 * 60 * 60)
        check(cache.load(synced, now: muchLater) == .synced(lines), "synced never expires")
        check(cache.load(missing, now: muchLater) == nil, "not-found expires")

        cache.save(.plain("text"), for: missing, now: now)
        cache.removeUnsynced()
        check(cache.load(missing, now: now) == nil, "removeUnsynced drops plain")
        check(cache.load(synced, now: now) == .synced(lines), "removeUnsynced keeps synced")
    }
}
