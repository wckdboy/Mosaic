import CoreGraphics
import Foundation
import Testing
import UIKit

@testable import Mosaic

// The smart index and the two-axis canvas are pure enough to verify without media:
// synthetic images for palette analysis, synthetic vectors for semantic ranking.
struct VisualIndexTests {
    private func image(_ color: UIColor, size: CGSize = CGSize(width: 64, height: 64)) -> CGImage {
        UIGraphicsImageRenderer(size: size).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }.cgImage!
    }
    @Test func dominantColorNamesFollowTheWheel() {
        #expect(MosaicAnalysis.describe(image(.systemBlue))?.color == "Blue")
        #expect(MosaicAnalysis.describe(image(UIColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)))?.color == "Red")
        #expect(MosaicAnalysis.describe(image(.black))?.color == "Dark")
        #expect(MosaicAnalysis.describe(image(.white))?.color == "Light")
        let descriptor = MosaicAnalysis.describe(image(.systemGreen))
        #expect(descriptor?.color == "Green")
        #expect(descriptor?.isCurrent == true)
        #expect(descriptor?.palette?.isEmpty == false)
    }
    @Test func paletteDominatesOverSmallAccents() {
        // A small red accent on a large blue field stays a blue image with a red swatch.
        let size = CGSize(width: 96, height: 96)
        let cg = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 30, height: 96))
        }.cgImage!
        let descriptor = MosaicAnalysis.describe(cg)
        #expect(descriptor?.color == "Blue")
        #expect((descriptor?.palette?.count ?? 0) >= 2)
    }
    @Test func quantizedFeaturesPreserveCosineOrder() throws {
        let a = try #require(MosaicAnalysis.quantize([1, 0, 0, 0]))
        let near = try #require(MosaicAnalysis.quantize([0.9, 0.1, 0, 0]))
        let far = try #require(MosaicAnalysis.quantize([0, 0, 1, 0]))
        #expect(VisualMetric.featureDistance(a, a) < 0.01)
        #expect(VisualMetric.featureDistance(a, near) < VisualMetric.featureDistance(a, far))
        #expect(abs(VisualMetric.featureDistance(a, far) - 1) < 0.01)
        #expect(MosaicAnalysis.quantize([0, 0]) == nil)
    }
    @Test func visionLabelsMapToThemes() {
        #expect(MediaTheme.theme(for: [("dog", 0.9), ("animal", 0.95)]) == "Animals")
        #expect(MediaTheme.theme(for: [("beach", 0.6), ("sky", 0.3)]) == "Water & Beach")
        #expect(MediaTheme.theme(for: [("sunset_sunrise", 0.8)]) == "Sky")
        #expect(MediaTheme.theme(for: [("unknown_thing", 0.9)]) == MediaTheme.fallback)
        #expect(MediaTheme.theme(for: [("dog", 0.05)]) == MediaTheme.fallback)
    }
    @Test func olderDescriptorsDecodeAndAreMarkedStale() throws {
        let json = Data(#"{"color":"Blue","hash":5}"#.utf8)
        let descriptor = try JSONDecoder().decode(VisualDescriptor.self, from: json)
        #expect(descriptor.color == "Blue")
        #expect(!descriptor.isCurrent)
    }
}

struct SemanticDiscoveryTests {
    private func item(_ id: String, _ kind: MediaItem.Kind = .photo) -> MediaItem {
        MediaItem(id: id, name: "\(id).jpg", kind: kind, date: .distantPast)
    }
    private func descriptor(
        _ vector: [Float], color: UInt32, theme: String, labels: [String]
    ) -> VisualDescriptor {
        VisualDescriptor(
            color: "Blue", hash: 0, version: VisualDescriptor.currentVersion, hue: 0.6, saturation: 0.5,
            brightness: 0.5, palette: [color], labels: labels, theme: theme,
            feature: MosaicAnalysis.quantize(vector))
    }
    @Test func featurePrintsRankMostSimilarFirstAcrossKinds() {
        let seed = item("seed")
        let close = item("close", .video)
        let mid = item("mid", .animated)
        let far = item("far")
        let visual = [
            "seed": descriptor([1, 0, 0], color: 0x2050C0, theme: "Sky", labels: ["sky"]),
            "close": descriptor([0.95, 0.05, 0], color: 0x2050C0, theme: "Sky", labels: ["sky"]),
            "mid": descriptor([0.7, 0.3, 0], color: 0x2060B0, theme: "Sky", labels: ["sky", "cloud"]),
            "far": descriptor([0, 0, 1], color: 0xC02020, theme: "Food & Drink", labels: ["food"]),
        ]
        let matches = MosaicSimilarity.matches(
            seed: seed, items: [far, mid, seed, close], mode: .similar, descriptors: visual)
        #expect(matches.map(\.id) == ["close", "mid"])
        let themed = MosaicSimilarity.matches(
            seed: seed, items: [far, mid, close], mode: .theme, descriptors: visual)
        #expect(themed.map(\.id) == ["close", "mid"])
        let colored = MosaicSimilarity.matches(
            seed: seed, items: [far, mid, close], mode: .color, descriptors: visual)
        #expect(colored.first?.id == "close")
        #expect(!colored.contains { $0.id == "far" })
    }
    @Test func searchMatchesVisualLabelsThemesAndColors() {
        let photo = item("photos:1")
        let visual = ["photos:1": descriptor([1], color: 0x2050C0, theme: "Animals", labels: ["dog", "golden_retriever"])]
        #expect(MosaicFilter(query: "dog").matches(photo, favorites: [], text: [:], visual: visual))
        #expect(MosaicFilter(query: "golden retriever").matches(photo, favorites: [], text: [:], visual: visual))
        #expect(MosaicFilter(query: "animals blue").matches(photo, favorites: [], text: [:], visual: visual))
        #expect(!MosaicFilter(query: "cat").matches(photo, favorites: [], text: [:], visual: visual))
        #expect(!MosaicFilter(query: "dog").matches(photo, favorites: [], text: [:]))
    }
    @Test func colorIslandsFollowTheColorWheel() {
        let items = ["a", "b", "c", "d"].map { item($0) }
        let visual: [String: VisualDescriptor] = [
            "a": VisualDescriptor(color: "Blue", hash: 0),
            "b": VisualDescriptor(color: "Red", hash: 0),
            "c": VisualDescriptor(color: "Green", hash: 0),
        ]
        let titles = MosaicClusterBuilder.clusters(
            items: items, mode: .color, descriptors: visual, sentiments: [:]
        ).map(\.title)
        #expect(titles == ["Red", "Green", "Blue", MosaicClusterBuilder.notAnalyzed])
    }
}

@MainActor struct CanvasLayoutTests {
    private func items(_ count: Int) -> [MediaItem] {
        (0..<count).map { MediaItem(id: "\($0)", name: "\($0).jpg", kind: .photo, date: .distantPast) }
    }
    private func frames(_ layout: MosaicCanvasLayout, _ clusters: [MosaicCluster]) -> [CGRect] {
        clusters.indices.flatMap { section in
            clusters[section].items.indices.compactMap { layout.baseFrame(at: IndexPath(item: $0, section: section)) }
        }
    }
    @Test func islandTilesNeverOverlap() {
        let clusters = [3, 1, 17, 40, 2, 9].enumerated().map { index, count in
            MosaicCluster(id: "\(index)", title: "\(index)", items: items(count))
        }
        let layout = MosaicCanvasLayout()
        layout.clusters = clusters
        layout.prepare()
        let all = frames(layout, clusters)
        #expect(all.count == clusters.reduce(0) { $0 + $1.items.count })
        for (index, frame) in all.enumerated() {
            for other in all[(index + 1)...] { #expect(!frame.insetBy(dx: 1, dy: 1).intersects(other)) }
        }
    }
    @Test func focusedLayoutCentersReferenceAndRadiatesByRank() {
        let cluster = MosaicCluster(id: "matches", title: "Related", items: items(120))
        let layout = MosaicCanvasLayout()
        layout.focused = true
        layout.clusters = [cluster]
        layout.prepare()
        let all = frames(layout, [cluster])
        let hero = all[0]
        #expect(hero.width > all[1].width * 1.9)
        #expect(layout.focusPoint == CGPoint(x: hero.midX, y: hero.midY))
        func distance(_ frame: CGRect) -> CGFloat { hypot(frame.midX - hero.midX, frame.midY - hero.midY) }
        // Closest matches sit nearest the hero; the last ranked ones sit farthest out.
        #expect(distance(all[1]) < distance(all[119]))
        // Content extends on every side of the hero, so panning works in all directions.
        #expect(hero.minX > 300 && hero.minY > 300)
        #expect(layout.baseSize.width - hero.maxX > 300 && layout.baseSize.height - hero.maxY > 300)
        for (index, frame) in all.enumerated() {
            for other in all[(index + 1)...] { #expect(!frame.insetBy(dx: 1, dy: 1).intersects(other)) }
        }
    }
    @Test func zoomScalesQueriesWithoutRelayout() {
        let cluster = MosaicCluster(id: "all", title: "All", items: items(5_000))
        let layout = MosaicCanvasLayout()
        layout.clusters = [cluster]
        layout.prepare()
        let base = layout.collectionViewContentSize
        layout.scale = 0.5
        #expect(abs(layout.collectionViewContentSize.width - base.width / 2) < 0.5)
        let rect = CGRect(x: 0, y: 0, width: 400, height: 800)
        let zoomedOut = layout.layoutAttributesForElements(in: rect)?.filter { $0.representedElementCategory == .cell } ?? []
        layout.scale = 1
        let normal = layout.layoutAttributesForElements(in: rect)?.filter { $0.representedElementCategory == .cell } ?? []
        #expect(zoomedOut.count > normal.count * 2)
        layout.scale = 100
        #expect(layout.scale == MosaicCanvasLayout.scaleRange.upperBound)
    }
}

struct ContinuingDiscoveryTests {
    @Test func canvasDiscoveryContinuesPastCloseMatchesInRankOrder() {
        func item(_ id: String) -> MediaItem { MediaItem(id: id, name: "\(id).jpg", kind: .photo, date: .distantPast) }
        func visual(_ v: [Float]) -> VisualDescriptor {
            VisualDescriptor(color: "Blue", hash: 0, version: 2, palette: [0x2050C0], feature: MosaicAnalysis.quantize(v))
        }
        let descriptors = [
            "seed": visual([1, 0, 0]), "close": visual([0.95, 0.05, 0]),
            "far": visual([0, 0, 1]), "farther": visual([-1, 0, 0]),
        ]
        let items = ["farther", "far", "close", "seed", "unknown"].map(item)
        let strict = MosaicSimilarity.matches(seed: item("seed"), items: items, mode: .similar, descriptors: descriptors)
        #expect(strict.map(\.id) == ["close"])
        let open = MosaicSimilarity.matches(
            seed: item("seed"), items: items, mode: .similar, descriptors: descriptors, continuing: true)
        // Unanalyzed items are never presented as visual matches, even far out.
        #expect(open.map(\.id) == ["close", "far", "farther"])
    }
    @Test func analyzedReferenceStillReachesUnanalyzedNameSharesLast() {
        let seed = MediaItem(id: "seed", name: "Trip_001.jpg", kind: .photo, date: .distantPast)
        let sibling = MediaItem(id: "sibling", name: "Trip_002.jpg", kind: .photo, date: .distantPast)
        let other = MediaItem(id: "other", name: "Receipt.jpg", kind: .photo, date: .distantPast)
        let descriptors = ["seed": VisualDescriptor(color: "Blue", hash: 0)]
        #expect(MosaicSimilarity.matches(seed: seed, items: [seed, sibling, other], mode: .similar, descriptors: descriptors).isEmpty)
        #expect(
            MosaicSimilarity.matches(
                seed: seed, items: [seed, sibling, other], mode: .similar, descriptors: descriptors, continuing: true
            ).map(\.id) == ["sibling"])
    }
}

@MainActor struct CanvasOverviewTests {
    private func items(_ count: Int) -> [MediaItem] {
        (0..<count).map { MediaItem(id: "\($0)", name: "\($0).jpg", kind: .photo, date: .distantPast) }
    }
    @Test func farZoomShowsMapInsteadOfCells() {
        let layout = MosaicCanvasLayout()
        layout.clusters = [MosaicCluster(id: "all", title: "All", items: items(20_000))]
        layout.prepare()
        layout.scale = 0.05
        #expect(!layout.showsCells)
        let everything = CGRect(origin: .zero, size: layout.collectionViewContentSize)
        // No per-item attributes at all: the whole world is one pre-rendered bitmap.
        let cells = layout.layoutAttributesForElements(in: everything)?.filter {
            $0.representedElementCategory == .cell
        }
        #expect(cells?.isEmpty == true)
        #expect(layout.allFrames().flatMap { $0 }.count == 20_000)
        layout.scale = 1
        #expect(layout.showsCells)
    }
    @Test func minimumZoomFitsEveryItem() {
        let layout = MosaicCanvasLayout()
        layout.clusters = [MosaicCluster(id: "all", title: "All", items: items(50_000))]
        layout.prepare()
        // Without a view the fit assumes a 400×800 viewport.
        layout.scale = layout.minimumScale
        let size = layout.collectionViewContentSize
        #expect(size.width <= 400 && size.height <= 800)
        #expect(layout.minimumScale < 0.05)
    }
}
