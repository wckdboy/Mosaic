#if DEBUG
    import SwiftUI
    import UIKit

    // UI tests use a separate archive and procedural images inside the app sandbox.
    // This code is absent from Release builds and never requests Photos/provider access.
    enum UITestFixture {
        @MainActor static func storeIfRequested() -> LibraryStore? {
            guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return nil }
            // A launch-argument default is immutable during a run; initialize
            // this setting here so the tests can actually switch to the canvas.
            UserDefaults.standard.set("gallery", forKey: "libraryLayout")
            do {
                let root = URL.temporaryDirectory.appending(
                    path: "Mosaic-UI-Tests", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                var archive = LibraryArchive()
                for index in 0..<60 {
                    let name = String(format: "Study_%03d.jpg", index + 1)
                    let url = root.appending(path: name)
                    if !FileManager.default.fileExists(atPath: url.path) {
                        let image = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 300)).image {
                            context in
                            UIColor(
                                hue: CGFloat(index % 12) / 12, saturation: 0.35, brightness: 0.7, alpha: 1
                            ).setFill()
                            context.fill(CGRect(x: 0, y: 0, width: 240, height: 300))
                            UIColor.white.withAlphaComponent(0.6).setFill()
                            context.cgContext.fillEllipse(
                                in: CGRect(x: 30, y: 45 + index % 4 * 20, width: 180, height: 180))
                        }
                        try image.jpegData(compressionQuality: 0.8)?.write(to: url, options: .atomic)
                    }
                    archive.files.append(
                        MediaItem(
                            id: "fixture:\(index)", name: name, kind: .photo,
                            date: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)), fileURL: url))
                }
                let archiveURL = root.appending(path: "library.json")
                try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
                return LibraryStore(repository: ArchiveRepository(url: archiveURL), isolated: true)
            } catch { preconditionFailure("Unable to prepare isolated UI fixtures: \(error)") }
        }
    }
#endif
