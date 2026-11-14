import ImageIO
import XCTest
import zlib

@testable import Schrift

final class ImagePreparationTests: XCTestCase {
    func testDownscalesLargeImagesToMaxEdge() throws {
        let jpeg = try XCTUnwrap(preparedJPEGData(from: testPNGData(width: 3000, height: 1500)))
        let size = try XCTUnwrap(testPixelSize(of: jpeg))
        XCTAssertEqual(size.width, 2048)
        XCTAssertEqual(size.height, 1024)
    }

    func testDownscalesOnTheLongEdgeWhateverItsOrientation() throws {
        let jpeg = try XCTUnwrap(preparedJPEGData(from: testPNGData(width: 1500, height: 3000)))
        let size = try XCTUnwrap(testPixelSize(of: jpeg))
        XCTAssertEqual(size.width, 1024)
        XCTAssertEqual(size.height, 2048)
    }

    func testSmallImagesAreNotUpscaled() throws {
        let jpeg = try XCTUnwrap(preparedJPEGData(from: testPNGData(width: 100, height: 80)))
        let size = try XCTUnwrap(testPixelSize(of: jpeg))
        XCTAssertEqual(size.width, 100)
        XCTAssertEqual(size.height, 80)
    }

    /// The filename extension we upload (`photo.jpg`) must match the sniffed
    /// bytes, or the backend stores the attachment `-unsafe` and it won't render.
    func testOutputIsJPEG() throws {
        let jpeg = try XCTUnwrap(preparedJPEGData(from: testPNGData(width: 10, height: 10)))
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))
    }

    func testHonoursACustomMaxPixelSize() throws {
        let jpeg = try XCTUnwrap(preparedJPEGData(from: testPNGData(width: 800, height: 400), maxPixelSize: 200))
        let size = try XCTUnwrap(testPixelSize(of: jpeg))
        XCTAssertEqual(size.width, 200)
        XCTAssertEqual(size.height, 100)
    }

    /// The upload must not geotag the user. `preparedJPEGData` rebuilds the output
    /// from a bare `CGImage`, passing only the compression quality — copying the
    /// source properties into `CGImageDestinationAddImage` is one line away and
    /// would silently ship GPS coordinates to the server.
    func testStripsGPSAndIdentifyingMetadata() throws {
        let original = testJPEGDataWithGPSMetadata(width: 60, height: 40)
        let sourceProperties = try XCTUnwrap(testImageProperties(of: original))
        XCTAssertNotNil(sourceProperties[kCGImagePropertyGPSDictionary], "fixture must actually carry GPS")

        let prepared = try XCTUnwrap(preparedJPEGData(from: original))

        let properties = try XCTUnwrap(testImageProperties(of: prepared))
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "GPS coordinates must never be uploaded")
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary])
        // Belt and braces: the identifying strings must not survive anywhere in the
        // bytes, not merely be absent from the parsed property dictionaries.
        for secret in ["SecretLens 50mm", "SecretMake", "2026:07:08 12:00:00"] {
            XCTAssertNil(prepared.range(of: Data(secret.utf8)), "\"\(secret)\" leaked into the upload")
        }
    }

    func testNonImageDataReturnsNil() {
        XCTAssertNil(preparedJPEGData(from: Data([0x00, 0x01, 0x02])))
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(preparedJPEGData(from: Data()))
    }

    func testDecompressionBombAbovePixelLimitReturnsNil() throws {
        // Valid 1-bit grayscale 10,001 x 10,001 PNG (> 100 MP cap) compressing to ~15 KB.
        let bomb = makeMinimal1BitPNG(width: 10_001, height: 10_001)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bomb as CFData, nil))
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary)
                as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 10_001)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 10_001)

        XCTAssertNil(preparedJPEGData(from: bomb))
    }

    private func makeMinimal1BitPNG(width: Int, height: Int) -> Data {
        func appendChunk(_ type: String, body: Data, to out: inout Data) {
            var lengthBE = UInt32(body.count).bigEndian
            out.append(Data(bytes: &lengthBE, count: 4))
            var typeAndBody = Data(type.utf8)
            typeAndBody.append(body)
            out.append(typeAndBody)
            let crc = typeAndBody.withUnsafeBytes { ptr in
                crc32(0, ptr.bindMemory(to: Bytef.self).baseAddress, uInt(ptr.count))
            }
            var crcBE = UInt32(crc).bigEndian
            out.append(Data(bytes: &crcBE, count: 4))
        }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        var wBE = UInt32(width).bigEndian
        var hBE = UInt32(height).bigEndian
        ihdr.append(Data(bytes: &wBE, count: 4))
        ihdr.append(Data(bytes: &hBE, count: 4))
        ihdr.append(contentsOf: [1, 0, 0, 0, 0])  // 1-bit grayscale, deflate, standard filter, non-interlaced
        appendChunk("IHDR", body: ihdr, to: &png)

        let rowBytes = 1 + (width + 7) / 8
        let raw = Data(count: rowBytes * height)
        var destLen = compressBound(uLong(raw.count))
        var compressed = Data(count: Int(destLen))
        let status = raw.withUnsafeBytes { srcPtr in
            compressed.withUnsafeMutableBytes { dstPtr in
                compress2(
                    dstPtr.bindMemory(to: Bytef.self).baseAddress,
                    &destLen,
                    srcPtr.bindMemory(to: Bytef.self).baseAddress,
                    uLong(raw.count),
                    Z_BEST_SPEED)
            }
        }
        XCTAssertEqual(status, Z_OK)
        compressed.count = Int(destLen)
        appendChunk("IDAT", body: compressed, to: &png)
        appendChunk("IEND", body: Data(), to: &png)
        return png
    }
}
