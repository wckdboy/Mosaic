import CoreGraphics
import CoreText
import Foundation
import UIKit

// Rendering happens outside the browsing path. Collages use UIGraphics for its
// simple rounded-corner and image drawing, while photobooks use a Core Graphics PDF
// context so pages can be written one at a time instead of holding an entire book in
// memory.
enum CreationExporter {
    /// Long edge for an exported collage image. Large enough for a crisp print,
    /// small enough that a 20-photo collage does not exhaust a phone's memory.
    static let collageLongEdge: CGFloat = 2_600

    // MARK: - Collage

    static func collage(
        project: CreationProject, items: [MediaItem], layout: CoreCollageLayout,
        longEdge: CGFloat = collageLongEdge
    ) async -> UIImage? {
        let aspect = max(layout.aspect, 0.1)
        let size =
            aspect >= 1
            ? CGSize(width: longEdge, height: longEdge / aspect)
            : CGSize(width: longEdge * aspect, height: longEdge)
        var lookup: [String: MediaItem] = [:]
        for item in items { lookup[item.id] = item }
        var images: [String: UIImage] = [:]
        for cell in layout.cells {
            guard let id = cell.id, images[id] == nil, let item = lookup[id] else { continue }
            let pixels = Int(max(cell.w * size.width, cell.h * size.height) * 1.2)
            if let image = await MediaImageLoader.image(for: item, pixels: pixels) {
                images[id] = image
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            drawBackground(context, finish: project.finish, size: size)
            for cell in layout.cells.sorted(by: { $0.z < $1.z }) {
                guard let id = cell.id, let image = images[id] else { continue }
                drawImage(
                    image,
                    in: CGRect(
                        x: cell.x * size.width, y: cell.y * size.height,
                        width: cell.w * size.width, height: cell.h * size.height),
                    cornerRadius: project.cornerRadius * (size.width / 390),
                    rotation: cell.rotation, focusX: cell.focusX, focusY: cell.focusY,
                    context: context)
            }
        }
    }

    private static func drawBackground(_ context: CGContext, finish: CollageFinish, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        if finish == .accent {
            let colors =
                [
                    UIColor(red: 0.62, green: 0.18, blue: 0.86, alpha: 1).cgColor,
                    UIColor(red: 0.98, green: 0.58, blue: 0.16, alpha: 1).cgColor,
                ] as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            {
                context.drawLinearGradient(
                    gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
                return
            }
        }
        let (r, g, b) = finish.components
        context.setFillColor(red: r, green: g, blue: b, alpha: 1)
        context.fill(rect)
    }

    // MARK: - Photobook

    static func bookPDF(
        project: CreationProject, plan: CoreBookPlan, items: [MediaItem]
    ) async -> URL? {
        guard !plan.pages.isEmpty else { return nil }
        var lookup: [String: MediaItem] = [:]
        for item in items { lookup[item.id] = item }
        let pageWidth: CGFloat = 1_200
        let pageHeight = pageWidth / max(plan.pageAspect, 0.4)
        let target = URL.temporaryDirectory.appending(
            path: "\(safeFilename(project.title.isEmpty ? "Mosaic book" : project.title)).pdf")
        try? FileManager.default.removeItem(at: target)
        guard let consumer = CGDataConsumer(url: target as CFURL) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        for page in plan.pages {
            // Load only the photographs on this page. A large book therefore has a
            // flat memory profile regardless of total photo count.
            var pageImages: [String: UIImage] = [:]
            for cell in page.cells {
                guard pageImages[cell.id] == nil, let item = lookup[cell.id] else { continue }
                let pixels = Int(max(cell.w * pageWidth, cell.h * pageHeight) * 1.35)
                if let image = await MediaImageLoader.image(for: item, pixels: pixels) {
                    pageImages[cell.id] = image
                }
            }
            context.beginPDFPage(nil)
            drawBackground(
                context, finish: project.finish, size: CGSize(width: pageWidth, height: pageHeight))
            for cell in page.cells.sorted(by: { $0.z < $1.z }) {
                guard let image = pageImages[cell.id] else { continue }
                let rect = CGRect(
                    x: cell.x * pageWidth,
                    y: (1 - cell.y - cell.h) * pageHeight,
                    width: cell.w * pageWidth, height: cell.h * pageHeight)
                drawCoreGraphicsImage(
                    image, in: rect, pageHeight: pageHeight, cornerRadius: 0,
                    rotation: cell.rotation, focusX: cell.focusX, focusY: cell.focusY,
                    context: context)
            }
            if page.kind == "cover" {
                drawCoverText(page, size: CGSize(width: pageWidth, height: pageHeight), context: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return target
    }

    private static func drawImage(
        _ image: UIImage, in rect: CGRect, cornerRadius: CGFloat, rotation: Double,
        focusX: Double, focusY: Double, context: CGContext
    ) {
        guard let cgImage = image.cgImage else { return }
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: rotation * .pi / 180)
        let local = CGRect(
            x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
        if cornerRadius > 0 {
            let path = CGPath(
                roundedRect: local, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                transform: nil)
            context.addPath(path)
            context.clip()
        }
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        guard imageWidth > 0, imageHeight > 0 else {
            context.restoreGState()
            return
        }
        let scale = max(local.width / imageWidth, local.height / imageHeight)
        let drawSize = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        let drawRect = CGRect(
            x: local.midX - drawSize.width * focusX,
            y: local.midY - drawSize.height * focusY,
            width: drawSize.width, height: drawSize.height)
        context.interpolationQuality = .high
        context.draw(cgImage, in: drawRect)
        context.restoreGState()
    }

    /// PDF coordinates grow upward. Cells are authored in top-left coordinates, so
    /// this helper converts, rotates, and clips in one place.
    private static func drawCoreGraphicsImage(
        _ image: UIImage, in rect: CGRect, pageHeight: CGFloat, cornerRadius: CGFloat,
        rotation: Double, focusX: Double, focusY: Double, context: CGContext
    ) {
        guard let cgImage = image.cgImage else { return }
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: -rotation * .pi / 180)
        let local = CGRect(
            x: -rect.width / 2, y: -rect.height / 2, width: rect.width, height: rect.height)
        if cornerRadius > 0 {
            context.addPath(
                CGPath(
                    roundedRect: local, cornerWidth: cornerRadius, cornerHeight: cornerRadius,
                    transform: nil))
            context.clip()
        }
        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)
        guard imageWidth > 0, imageHeight > 0 else {
            context.restoreGState()
            return
        }
        let scale = max(local.width / imageWidth, local.height / imageHeight)
        let drawSize = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        let drawRect = CGRect(
            x: local.midX - drawSize.width * focusX,
            y: local.midY - drawSize.height * focusY,
            width: drawSize.width, height: drawSize.height)
        context.interpolationQuality = .high
        context.draw(cgImage, in: drawRect)
        context.restoreGState()
        _ = pageHeight
    }

    private static func drawCoverText(
        _ page: CoreBookPage, size: CGSize, context: CGContext
    ) {
        let margin: CGFloat = 76
        // A soft bottom gradient keeps white type readable over any cover photo.
        let colors =
            [
                UIColor.black.withAlphaComponent(0).cgColor,
                UIColor.black.withAlphaComponent(0.72).cgColor,
            ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
        {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: size.height * 0.55),
                end: CGPoint(x: 0, y: size.height * 0.05), options: [])
        }
        if !page.title.isEmpty {
            drawText(
                page.title, at: CGPoint(x: margin, y: margin + 54),
                font: .systemFont(ofSize: 58, weight: .semibold), color: .white,
                maxWidth: size.width - margin * 2, context: context)
        }
        if !page.subtitle.isEmpty {
            drawText(
                page.subtitle, at: CGPoint(x: margin, y: margin + 20),
                font: .systemFont(ofSize: 25, weight: .regular),
                color: UIColor.white.withAlphaComponent(0.82),
                maxWidth: size.width - margin * 2, context: context)
        }
    }

    private static func drawText(
        _ text: String, at point: CGPoint, font: UIFont, color: UIColor, maxWidth: CGFloat,
        context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color,
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        context.saveGState()
        context.textMatrix = .identity
        if width > maxWidth, width > 0 {
            context.concatenate(CGAffineTransform(scaleX: maxWidth / width, y: 1))
        }
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = value.unicodeScalars
            .map { allowed.contains($0) ? Character(String($0)) : "-" }
            .prefix(64)
        let name = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Mosaic book" : name
    }
}
