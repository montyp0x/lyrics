import Foundation

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    let text: String
}

enum LRCParser {
    /// Parses `[mm:ss.xx] text` lines. A line may carry several timestamps; metadata tags such as `[ar:...]` are skipped.
    static func parse(_ lrc: String) -> [LyricLine] {
        var entries: [(time: TimeInterval, text: String)] = []
        for rawLine in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(rawLine)
            var times: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                guard let time = parseTimestamp(tag) else { break }
                times.append(time)
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            entries.append(contentsOf: times.map { ($0, text) })
        }
        return entries
            .enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .enumerated()
            .map { LyricLine(id: $0.offset, time: $0.element.element.time, text: $0.element.element.text) }
    }

    /// Index of the line being sung at `time`, or nil before the first line.
    static func index(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        var low = 0
        var high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    private static func parseTimestamp(_ tag: Substring) -> TimeInterval? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}
