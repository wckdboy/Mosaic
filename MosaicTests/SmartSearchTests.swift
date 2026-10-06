import Foundation
import Testing

@testable import Mosaic

// Ranked search: literal hits on precise tags, labels, captions, and metadata come
// first; conceptually related media are separate and never mixed into the matches.
struct SmartSearchTests {
    private func item(_ id: String, name: String = "IMG.jpg", year: Int = 2024) -> MediaItem {
        let date = Calendar.current.date(from: DateComponents(year: year, month: 6, day: 1)) ?? .distantPast
        return MediaItem(id: id, name: name, kind: .photo, date: date)
    }
    private func described(_ tags: [String], caption: String = "", labels: [String] = []) -> VisualDescriptor {
        VisualDescriptor(
            color: "Blue", hash: 0, version: 2, labels: labels, theme: nil, people: nil, caption: caption, tags: tags,
            detailed: true, meaning: MediaSemantics.vector(for: tags.flatMap(MediaSemantics.words)))
    }

    @Test func preciseTagsRankFirstAndPluralsMatch() {
        let items = [item("a"), item("b"), item("c")]
        let visual = [
            "a": described(["woman", "coffee", "cafe"], caption: "A woman drinking coffee in a cafe"),
            "b": described(["man", "laptop", "office"]),
            "c": described(["dog", "park"]),
        ]
        let woman = MosaicSearch("woman").rank(items, descriptors: visual, text: [:])
        #expect(woman.matches.map(\.id) == ["a"])
        // Near-opposites must not leak in as "related" when literal matches exist.
        #expect(!woman.related.contains { $0.id == "b" })
        #expect(MosaicSearch("women").rank(items, descriptors: visual, text: [:]).matches.map(\.id) == ["a"])
        #expect(MosaicSearch("dogs").rank(items, descriptors: visual, text: [:]).matches.map(\.id) == ["c"])
    }
    @Test func everyTermMustMatchForABestMatch() {
        let items = [item("a"), item("b")]
        let visual = ["a": described(["woman", "beach"]), "b": described(["woman", "office"])]
        #expect(MosaicSearch("woman on the beach").rank(items, descriptors: visual, text: [:]).matches.map(\.id) == ["a"])
    }
    @Test func ideasFindConceptuallyRelatedMedia() {
        let items = [item("beach"), item("food"), item("dog")]
        let visual = [
            "beach": described(["beach", "sea", "sand", "sun", "vacation"]),
            "food": described(["pasta", "plate", "dinner", "restaurant"]),
            "dog": described(["dog", "grass", "park", "ball"]),
        ]
        let ocean = MosaicSearch("ocean").rank(items, descriptors: visual, text: [:])
        #expect(ocean.matches.isEmpty)
        #expect(ocean.related.first?.id == "beach")
        #expect(!ocean.related.contains { $0.id == "food" })
        #expect(MosaicSearch("meal").rank(items, descriptors: visual, text: [:]).related.first?.id == "food")
    }
    @Test func metadataLabelsTextAndPeopleCountAreSearchable() {
        let old = item("old", name: "Trip_Paris.jpg", year: 2019)
        let receipt = item("receipt")
        var group = VisualDescriptor(color: "Red", hash: 0)
        group.people = 4
        group.labels = ["birthday_cake"]
        let visual = ["receipt": group]
        let text = ["receipt": "Total 42 EUR"]
        let items = [old, receipt]
        #expect(MosaicSearch("2019").rank(items, descriptors: visual, text: text).matches.map(\.id) == ["old"])
        #expect(MosaicSearch("paris").rank(items, descriptors: visual, text: text).matches.map(\.id) == ["old"])
        #expect(MosaicSearch("birthday cake").rank(items, descriptors: visual, text: text).matches.map(\.id) == ["receipt"])
        #expect(MosaicSearch("group").rank(items, descriptors: visual, text: text).matches.map(\.id) == ["receipt"])
        #expect(MosaicSearch("eur").rank(items, descriptors: visual, text: text).matches.map(\.id) == ["receipt"])
        #expect(MosaicSearch("the of").isEmpty)
    }
    @Test func describerOutputIsNormalized() {
        let tags = MediaDescriber.normalize([["Woman", " woman ", "Coffee."], ["", "a", "Golden Retriever"]])
        #expect(tags == ["woman", "coffee", "golden retriever"])
    }
    @Test func topTagsPreferPreciseTagsAndSkipGenericLabels() {
        var visual: [String: VisualDescriptor] = [:]
        for index in 0..<5 {
            visual["\(index)"] = VisualDescriptor(
                color: "Blue", hash: 0, labels: ["outdoor", "sky"], tags: ["bicycle"], detailed: true)
        }
        let tags = MosaicView.topTags(visual)
        #expect(tags.first == "bicycle")
        #expect(!tags.contains("outdoor"))
    }
}
