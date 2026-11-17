import Foundation

/// Parses the TTML lyrics Apple Music returns: `<p begin="12.34" end="15.1">line</p>` per line, with optional
/// word-level `<span>`s inside. Lyrics without timings (`itunes:timing="None"`) come back as plain text.
enum TTMLParser {
    static func parse(_ ttml: String) -> LyricsLookup {
        var timed: [(time: TimeInterval, text: String)] = []
        var untimed: [String] = []
        for match in ttml.matches(of: #/<p\b([^>]*)>(.*?)</p>/#.dotMatchesNewlines()) {
            let text = plainText(String(match.output.2))
            let attributes = String(match.output.1)
            if let begin = attributes.firstMatch(of: #/\bbegin="([^"]+)"/#), let time = parseTime(String(begin.output.1)) {
                timed.append((time, text))
            } else if !text.isEmpty {
                untimed.append(text)
            }
        }
        if !timed.isEmpty {
            let lines = timed
                .sorted { $0.time < $1.time }
                .enumerated()
                .map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
            return .synced(lines)
        }
        return untimed.isEmpty ? .notFound : .plain(untimed.joined(separator: "\n"))
    }

    /// Accepts `12.34`, `1:02.345`, `01:02:03.456`, and an optional `s` suffix.
    static func parseTime(_ value: String) -> TimeInterval? {
        let trimmed = value.hasSuffix("s") ? String(value.dropLast()) : value
        var total: TimeInterval = 0
        for part in trimmed.split(separator: ":") {
            guard let number = Double(part) else { return nil }
            total = total * 60 + number
        }
        return total
    }

    private static func plainText(_ markup: String) -> String {
        markup
            // Background vocals follow the main words without a separating space.
            .replacing(#/<span[^>]*x-bg[^>]*>/#, with: " ")
            .replacing(#/<[^>]+>/#, with: "")
            .replacing(#/&(#[xX]?[0-9A-Fa-f]+|amp|apos|quot|lt|gt);/#) { decodeEntity(String($0.output.1)) }
            .replacing(#/\s+/#, with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Decodes in one pass, so `&amp;#39;` stays `&#39;` as written.
    private static func decodeEntity(_ name: String) -> String {
        switch name {
        case "amp": return "&"
        case "apos": return "'"
        case "quot": return "\""
        case "lt": return "<"
        case "gt": return ">"
        default:
            let hex = name.hasPrefix("#x") || name.hasPrefix("#X")
            let digits = name.dropFirst(hex ? 2 : 1)
            guard let code = UInt32(digits, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) else {
                return "&\(name);"
            }
            return String(Character(scalar))
        }
    }
}
