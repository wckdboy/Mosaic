import Foundation

// A small, strict parser for plain-text SRT and WebVTT sidecar subtitles. Styling
// markup is removed instead of rendered as HTML, keeping imported files inert.
struct SubtitleCue: Equatable, Sendable {
    let start: Double
    let end: Double
    let text: String

    static func parse(_ source: String) -> [SubtitleCue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
            of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.components(separatedBy: "\n")
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let range = lines[timingIndex].components(separatedBy: "-->")
            guard range.count == 2, let start = timestamp(range[0]), let end = timestamp(range[1]),
                end > start
            else { return nil }
            let content = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            guard !content.isEmpty else { return nil }
            return SubtitleCue(start: start, end: end, text: content)
        }.sorted { $0.start < $1.start }
    }
    static func timestamp(_ raw: String) -> Double? {
        let token = raw.trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first ?? ""
        let components = token.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")
        let parts = components.compactMap { Double($0) }
        guard parts.count == components.count else { return nil }
        guard parts.count == 2 || parts.count == 3, parts.allSatisfy({ $0.isFinite && $0 >= 0 }),
            let seconds = parts.last, seconds < 60, parts[parts.count - 2] < 60
        else { return nil }
        let total = parts.enumerated().reduce(0) {
            $0 + $1.element * pow(60, Double(parts.count - 1 - $1.offset))
        }
        return total.isFinite ? total : nil
    }
}
