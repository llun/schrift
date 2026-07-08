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

    func testNonImageDataReturnsNil() {
        XCTAssertNil(preparedJPEGData(from: Data([0x00, 0x01, 0x02])))
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(preparedJPEGData(from: Data()))
    }
}
