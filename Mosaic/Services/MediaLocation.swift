import Foundation
import ImageIO

// Reads capture coordinates from local image metadata. This never triggers an iCloud
// download and is intentionally limited to the file's own EXIF dictionary.
enum MediaLocation {
    static func coordinates(for url: URL) -> (latitude: Double, longitude: Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
            let longitude = gps[kCGImagePropertyGPSLongitude] as? Double
        else { return nil }
        let latitudeRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased()
        let longitudeRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased()
        let signedLatitude = latitudeRef == "S" ? -latitude : latitude
        let signedLongitude = longitudeRef == "W" ? -longitude : longitude
        guard signedLatitude.isFinite, signedLongitude.isFinite,
            abs(signedLatitude) <= 90, abs(signedLongitude) <= 180,
            signedLatitude != 0 || signedLongitude != 0
        else { return nil }
        return (signedLatitude, signedLongitude)
    }
}
