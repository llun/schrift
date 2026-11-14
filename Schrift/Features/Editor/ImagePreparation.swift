import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Maximum decoded pixel count allowed before thumbnailing/re-encoding (100 MP).
/// Accommodates 48 MP ProRAW photos while rejecting gigapixel decompression bombs.
let maximumPreparedImagePixels = 100_000_000

/// True when `data` sniffs as a non-SVG raster image container via ImageIO metadata.
func isNonSVGRasterImageData(_ data: Data) -> Bool {
    guard !data.isEmpty,
        let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
        let typeIdentifier = CGImageSourceGetType(source) as String?,
        let type = UTType(typeIdentifier)
    else { return false }
    return type.conforms(to: .image) && !type.conforms(to: .svg) && !type.conforms(to: .pdf)
}

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
/// Returns nil for undecodable or oversized (> 100 MP) images.
func preparedJPEGData(from data: Data, maxPixelSize: Int = 2048, compressionQuality: Double = 0.8) -> Data? {
    guard !data.isEmpty, maxPixelSize > 0,
        let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
        CGImageSourceGetCount(source) > 0,
        let properties = CGImageSourceCopyPropertiesAtIndex(
            source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int,
        width > 0, height > 0, width <= maximumPreparedImagePixels / height
    else { return nil }

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
