import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales an image (HEIC/PNG/JPEG…) to at most `maxPixelSize` on its long
/// edge and re-encodes it as JPEG. Uses ImageIO's thumbnail path so the full-
/// resolution bitmap is never decoded into memory, and bakes in the EXIF
/// orientation so the upload displays upright everywhere.
///
/// Re-encoding to JPEG is not cosmetic: the backend magic-sniffs the bytes and
/// stores the attachment under an `-unsafe` key (which won't render inline) if
/// they disagree with the filename extension. Always pairing this output with
/// `photo.jpg` / `image/jpeg` keeps the two in agreement.
///
/// **Privacy:** the output is rebuilt from a bare `CGImage`, passing only the
/// compression quality to the destination — so the original photo's EXIF
/// (including **GPS coordinates**) is dropped. Never copy the source properties
/// into `CGImageDestinationAddImage`; that would silently upload geotags.
///
/// Returns nil for undecodable data.
func preparedJPEGData(from data: Data, maxPixelSize: Int = 2048, compressionQuality: Double = 0.8) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let thumbnailOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
        return nil
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    let destinationOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compressionQuality]
    CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}
