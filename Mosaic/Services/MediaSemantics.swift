import Foundation
import NaturalLanguage

// Word vectors turn labels, tags, and queries into comparable "meaning" vectors.
// NLEmbedding is not documented as thread-safe, so one shared instance is locked.
enum MediaSemantics {
    nonisolated(unsafe) private static let embedding = NLEmbedding.wordEmbedding(for: .english)
    private static let lock = NSLock()
    // Words that carry no visual meaning in a search or description.
    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "in", "on", "at", "with", "and", "or", "to", "for", "from", "by", "is",
        "are", "this", "that", "some", "photo", "photos", "picture", "pictures", "image", "images",
        "show", "showing", "me", "my", "find", "all",
    ]

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopwords.contains($0) }
    }

    // Plural and simple suffix variants: "dogs" finds "dog", "women" finds "woman".
    static func stem(_ word: String) -> String {
        let irregular = ["women": "woman", "men": "man", "children": "child", "people": "person", "feet": "foot",
            "teeth": "tooth", "mice": "mouse", "geese": "goose"]
        if let base = irregular[word] { return base }
        if word.count > 4, word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.count > 4, word.hasSuffix("es"), ["ch", "sh", "ss", "x"].contains(where: { word.dropLast(2).hasSuffix($0) }) {
            return String(word.dropLast(2))
        }
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    // Mean of known word vectors, normalized and quantized like feature prints.
    static func vector(for words: [String]) -> Data? {
        guard let embedding, !words.isEmpty else { return nil }
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var used = 0
        lock.lock()
        for word in Set(words) {
            guard let vector = embedding.vector(for: word) ?? embedding.vector(for: stem(word)) else { continue }
            for index in sum.indices { sum[index] += vector[index] }
            used += 1
        }
        lock.unlock()
        guard used > 0 else { return nil }
        return MosaicAnalysis.quantize(sum.map(Float.init))
    }
    static func similarity(_ a: Data?, _ b: Data?) -> Float {
        guard let a, let b else { return 0 }
        return 1 - VisualMetric.featureDistance(a, b)
    }
}

// Ranked search over metadata and the local index. Every query term must match some
// field for a "best match"; media that only relate conceptually are returned
// separately as "related", never mixed in as if they matched.
struct MosaicSearch: Sendable {
    let terms: [String]
    let meaning: Data?
    // Calibrated on NLEmbedding word vectors: related concepts score ~0.5–0.75 and
    // unrelated ones mostly below 0.45, but near-opposites ("woman"/"man") can reach
    // 0.53. With literal matches, only strongly related media join them; without any,
    // the closest concepts are shown relative to the best one.
    static let strictRelated: Float = 0.6
    static let looseRelated: Float = 0.48

    init(_ query: String) {
        let words = MediaSemantics.words(query)
        terms = words.map(MediaSemantics.stem)
        meaning = MediaSemantics.vector(for: words)
    }
    var isEmpty: Bool { terms.isEmpty }

    struct Result: Sendable {
        var matches: [MediaItem] = []
        var related: [MediaItem] = []
    }

    // Field weights: precise tags and labels count most, then captions and text.
    func lexicalScore(_ item: MediaItem, descriptor: VisualDescriptor?, text: String?) -> Float? {
        var fields: [(words: Set<String>, weight: Float)] = []
        func add(_ strings: [String], _ weight: Float) {
            let set = Set(strings.flatMap { MediaSemantics.words($0).map(MediaSemantics.stem) })
            if !set.isEmpty { fields.append((set, weight)) }
        }
        if let descriptor {
            add(descriptor.tags ?? [], 3)
            add((descriptor.labels ?? []).map(MediaTheme.readable), 2.5)
            add([descriptor.caption ?? ""], 2)
            add([descriptor.color, descriptor.theme ?? ""], 1.5)
            if let people = descriptor.people, people > 0 {
                add(people == 1 ? ["person", "people", "portrait"] : ["people", "person", "group"], 1.5)
            }
        }
        add([text ?? ""], 1.5)
        add([(item.name as NSString).deletingPathExtension, item.format, item.kind.title], 1)
        add([String(Calendar.current.component(.year, from: item.date))], 1)
        var total: Float = 0
        for term in terms {
            var best: Float = 0
            for field in fields {
                if field.words.contains(term) {
                    best = max(best, field.weight)
                } else if term.count >= 3, field.words.contains(where: { $0.hasPrefix(term) }) {
                    best = max(best, field.weight * 0.6)
                }
            }
            guard best > 0 else { return nil }
            total += best
        }
        return total
    }

    func rank(
        _ items: [MediaItem], descriptors: [String: VisualDescriptor], text: [String: String],
        limit: Int = 2000
    ) -> Result {
        var matches: [(MediaItem, Float)] = []
        var candidates: [(MediaItem, Float)] = []
        for item in items {
            let descriptor = descriptors[item.id]
            let semantic = MediaSemantics.similarity(meaning, descriptor?.meaning)
            if let score = lexicalScore(item, descriptor: descriptor, text: text[item.id]) {
                matches.append((item, score + semantic))
            } else if semantic >= Self.looseRelated {
                candidates.append((item, semantic))
            }
        }
        let best = candidates.map(\.1).max() ?? 0
        let threshold = matches.isEmpty ? max(Self.looseRelated, best - 0.1) : Self.strictRelated
        let related = candidates.filter { $0.1 >= threshold }
        func ordered(_ list: [(MediaItem, Float)]) -> [MediaItem] {
            list.sorted { $0.1 == $1.1 ? $0.0.date > $1.0.date : $0.1 > $1.1 }.prefix(limit).map(\.0)
        }
        return Result(matches: ordered(matches), related: ordered(related))
    }
}
