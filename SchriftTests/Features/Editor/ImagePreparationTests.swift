import XCTest

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
}
