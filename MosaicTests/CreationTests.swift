import Foundation
import Testing
import UIKit

@testable import Mosaic

// These tests exercise the Rust bridge, layout schemas, project persistence, and
// export renderers with temporary procedural images. They never touch Photos or a
// cloud provider.
struct CreationTests {
    private func temporaryImage(_ color: UIColor) throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            UIColor.white.withAlphaComponent(0.65).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 60, y: 40, width: 180, height: 160))
        }
        try image.jpegData(compressionQuality: 0.8)?.write(to: url, options: .atomic)
        return url
    }

    private func items(_ count: Int) throws -> [MediaItem] {
        try (0..<count).map { index in
            let url = try temporaryImage(
                UIColor(
                    hue: CGFloat(index) / CGFloat(max(count, 1)), saturation: 0.4, brightness: 0.7, alpha: 1))
            return MediaItem(
                id: "file:\(url.path)", name: "Photo_\(index).jpg", kind: .photo,
                date: Date(timeIntervalSince1970: 1_700_000_000 - Double(index) * 3_600),
                width: 320, height: 240, fileURL: url)
        }
    }

    @Test func collageLayoutCoversEveryPhoto() throws {
        let media = try items(9)
        let request = CoreCollageRequest(
            count: media.count, aspect: 1, style: "mosaic", seed: 7,
            spacing: 0.018, padding: 0.02,
            items: media.map {
                CoreLayoutItem(
                    id: $0.id, width: $0.width, height: $0.height,
                    date: $0.date.timeIntervalSince1970, favorite: false, quality: 0.5)
            })
        let layout = try MosaicCoreBridge.collage(request)
        #expect(layout.cells.count == media.count)
        #expect(layout.cells.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.w > 0 && $0.h > 0 })
        #expect(layout.cells.allSatisfy { $0.x + $0.w <= 1.001 && $0.y + $0.h <= 1.001 })
        #expect(Set(layout.cells.compactMap(\.id)) == Set(media.map(\.id)))
    }

    @Test func photobookPlanUsesEveryPhotoAndMakesPages() throws {
        let media = try items(12)
        let request = CoreBookRequest(
            items: media.map {
                CoreBookItem(
                    id: $0.id, date: $0.date.timeIntervalSince1970, width: 320, height: 240,
                    theme: "Nature", color: "Green", favorite: false, quality: 0.6)
            },
            pageAspect: 0.707, spread: true, style: "editorial", seed: 3,
            includeCover: true, title: "Test book", subtitle: "A small story",
            maxPerPage: 4, spacing: 0.014, padding: 0.028)
        let plan = try MosaicCoreBridge.book(request)
        #expect(plan.pages.first?.kind == "cover")
        #expect(plan.photoCount == media.count)
        let placed = plan.pages.filter { $0.kind == "page" }.flatMap { $0.cells.map(\.id) }
        #expect(Set(placed) == Set(media.map(\.id)))
        #expect(plan.pages.contains { $0.side == "left" })
    }

    @Test func indexSupportsIncrementalQueryAndCuration() async throws {
        let index = MosaicCoreIndex()
        let vector = Data((0..<256).map { UInt8(($0 * 37) % 200) }).base64EncodedString()
        let other = Data((0..<256).map { UInt8(($0 * 11 + 9) % 200) }).base64EncodedString()
        let entries = (0..<40).map { position in
            CoreIndexItem(
                id: "item-\(position)", name: "IMG_\(position).jpg",
                date: 1_700_000_000 - Double(position) * 60,
                width: 4032, height: 3024, favorite: position == 4,
                kind: "photo", color: "Blue", theme: "Nature", labels: ["beach"],
                hash: "0", feature: position % 4 == 0 ? vector : other,
                meaning: nil, palette: [0x336699], quality: 0.5, detailed: false,
                sourceModified: nil)
        }
        let inserted = try await index.upsert(entries)
        #expect(inserted.count == entries.count)
        let results = try await index.query(
            CoreQueryRequest(
                id: "item-0", feature: nil, meaning: nil, limit: 10, ids: nil,
                excludeIds: [], minSimilarity: 0.5, mode: "visual", kinds: nil,
                dateFrom: nil, dateTo: nil, projectionSeed: nil))
        #expect(results.contains { $0.id == "item-4" })
        let selections = try await index.select(
            CoreSelectRequest(
                count: 8, ids: nil, excludeIds: [], diversity: 0.5,
                includeFavorites: true, kinds: nil, minGapSeconds: 30,
                dateFrom: nil, dateTo: nil, seed: 2, prefilter: nil, preferRecent: true))
        #expect(selections.count == 8)
        #expect(selections.contains { $0.id == "item-4" })
        _ = try await index.stats()
    }

    @Test func projectRoundTripsWithoutLosingTheRecipe() throws {
        var project = CreationProject.collage(itemIDs: ["a", "b", "c"])
        project.title = "Weekend"
        project.collageStyle = .hero
        project.collageAspect = .portrait
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(CreationProject.self, from: data)
        #expect(decoded == project)
        #expect(decoded.collageStyle == .hero)
        #expect(abs(decoded.aspect - CollageAspect.portrait.value) < 0.001)
    }

    @Test func collageExporterProducesAPrintSizedImage() async throws {
        let media = try items(4)
        var project = CreationProject.collage(itemIDs: media.map(\.id))
        project.showCaptions = true
        let request = CoreCollageRequest(
            count: media.count, aspect: 1, style: "grid", seed: 1,
            spacing: 0.02, padding: 0.03,
            items: media.map {
                CoreLayoutItem(
                    id: $0.id, width: 320, height: 240,
                    date: $0.date.timeIntervalSince1970, favorite: false, quality: 0.5)
            })
        let layout = try MosaicCoreBridge.collage(request)
        let image = await CreationExporter.collage(
            project: project, items: media, layout: layout, longEdge: 900)
        #expect(image != nil)
        #expect(image?.size.width == 900)
        #expect(image?.size.height == 900)
    }

    @Test func photobookExporterWritesAReadablePDF() async throws {
        let media = try items(5)
        var project = CreationProject.photobook(itemIDs: media.map(\.id))
        project.title = "Test flight"
        let request = CoreBookRequest(
            items: media.map {
                CoreBookItem(
                    id: $0.id, date: $0.date.timeIntervalSince1970, width: 320, height: 240,
                    theme: nil, color: "Neutral", favorite: false, quality: 0.5)
            },
            pageAspect: 0.707, spread: false, style: "classic", seed: 1,
            includeCover: true, title: project.title, subtitle: "",
            maxPerPage: 2, spacing: 0.014, padding: 0.028)
        let plan = try MosaicCoreBridge.book(request)
        let url = await CreationExporter.bookPDF(project: project, plan: plan, items: media)
        let value = try #require(url)
        defer { try? FileManager.default.removeItem(at: value) }
        let attributes = try FileManager.default.attributesOfItem(atPath: value.path)
        #expect((attributes[.size] as? Int ?? 0) > 2_000)
        #expect(FileManager.default.fileExists(atPath: value.path))
        let document = CGPDFDocument(value as CFURL)
        #expect(document?.numberOfPages == plan.pageCount)
    }
}
