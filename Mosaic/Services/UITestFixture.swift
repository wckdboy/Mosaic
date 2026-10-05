#if DEBUG
    import AVFoundation
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
                if ProcessInfo.processInfo.arguments.contains("--ui-testing-video") {
                    let url = root.appending(path: "Clip_001.mov")
                    if !FileManager.default.fileExists(atPath: url.path) { try writeClip(to: url) }
                    archive.files.insert(
                        MediaItem(
                            id: "fixture:video", name: "Clip_001.mov", kind: .video,
                            date: Date(timeIntervalSince1970: 1_700_000_100), duration: 6, fileURL: url),
                        at: 0)
                }
                let archiveURL = root.appending(path: "library.json")
                try JSONEncoder().encode(archive).write(to: archiveURL, options: .atomic)
                return LibraryStore(repository: ArchiveRepository(url: archiveURL), isolated: true)
            } catch { preconditionFailure("Unable to prepare isolated UI fixtures: \(error)") }
        }

        // A six-second procedural H.264 clip exercises the real video transport.
        private static func writeClip(to url: URL) throws {
            let size = CGSize(width: 320, height: 240)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width,
                    AVVideoHeightKey: size.height,
                ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
                ])
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)
            for frame in 0..<180 {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
                guard let pool = adaptor.pixelBufferPool else { break }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                guard let buffer else { break }
                CVPixelBufferLockBaseAddress(buffer, [])
                if let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue)
                {
                    let hue = CGFloat(frame) / 180
                    context.setFillColor(
                        UIColor(hue: hue, saturation: 0.5, brightness: 0.6, alpha: 1).cgColor)
                    context.fill(CGRect(origin: .zero, size: size))
                    context.setFillColor(UIColor.white.cgColor)
                    context.fillEllipse(in: CGRect(x: CGFloat(frame % 60) * 4, y: 80, width: 80, height: 80))
                }
                CVPixelBufferUnlockBaseAddress(buffer, [])
                adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
            }
            input.markAsFinished()
            let done = DispatchSemaphore(value: 0)
            writer.finishWriting { done.signal() }
            done.wait()
            if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
    }
#endif
