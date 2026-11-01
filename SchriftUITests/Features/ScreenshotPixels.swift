import XCTest

extension XCUIScreenshot {
    /// Reads one pixel of the screenshot as 8-bit RGB, addressed in points.
    func rgb(x: CGFloat, y: CGFloat) throws -> [Int] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let scale = CGFloat(cgImage.width) / image.size.width
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(
            cgImage,
            in: CGRect(
                x: -x * scale, y: -(CGFloat(cgImage.height) - 1 - y * scale), width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)))
        return pixel.prefix(3).map(Int.init)
    }
}

/// The largest per-channel difference between two `XCUIScreenshot.rgb` samples.
func colorDistance(_ lhs: [Int], _ rhs: [Int]) -> Int {
    zip(lhs, rhs).map { abs($0 - $1) }.max() ?? 0
}
