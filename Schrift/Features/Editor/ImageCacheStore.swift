import CryptoKit
import Foundation
import ImageIO
import UIKit

/// A decoded thumbnail keeps a compressed, oversized image from allocating an unbounded bitmap.
/// The source bytes on disk remain unchanged; this is display-only, never the photo upload path.
func imageThumbnail(at file: URL) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
            source, 0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
    else { return nil }
    return UIImage(cgImage: image)
}

/// Durable, backup-excluded image bytes. Names hash the complete URL, server and authenticated
/// session scope, so query changes, document paths and accounts cannot alias each other's bytes.
/// Unlike the file-attachment cache, even the newest image must fit the strict byte cap.
final class ImageCacheStore {
    static let maximumImageBytes = 12 * 1024 * 1024
    private let directory: URL
    private let fileManager: FileManager
    private let countLimit: Int
    private let byteLimit: Int

    init(
        directory: URL? = nil, fileManager: FileManager = .default,
        countLimit: Int = 100, byteLimit: Int = 64 * 1024 * 1024
    ) {
        self.fileManager = fileManager
        self.directory =
            directory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.llun.Schrift/ImageCache", isDirectory: true)
        self.countLimit = max(0, countLimit)
        self.byteLimit = max(0, byteLimit)
    }

    func cachedFileURL(for url: URL, serverOrigin: String, scope: String) -> URL? {
        let file = fileURL(for: url, serverOrigin: serverOrigin, scope: scope)
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return file
    }

    func store(_ data: Data, for url: URL, serverOrigin: String, scope: String) -> URL? {
        guard countLimit > 0, !data.isEmpty, data.count <= min(byteLimit, Self.maximumImageBytes),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 48_000_000 / height
        else { return nil }
        let file = fileURL(for: url, serverOrigin: serverOrigin, scope: scope)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            guard imageThumbnail(at: file) != nil else {
                try? fileManager.removeItem(at: file)
                return nil
            }
            evict(protecting: file)
            return fileManager.fileExists(atPath: file.path) ? file : nil
        } catch { return nil }
    }

    func removeAll() { try? fileManager.removeItem(at: directory) }

    private func fileURL(for url: URL, serverOrigin: String, scope: String) -> URL {
        // Length framing prevents delimiter collisions in freely constructible inputs.
        let key = [serverOrigin, scope, url.absoluteString].map { "\($0.utf8.count):\($0)" }.joined()
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }

    private func evict(protecting newest: URL) {
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        else { return }
        let ordered = files.sorted { left, right in
            if left == newest { return right != newest }
            if right == newest { return false }
            let l =
                (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            let r =
                (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            return l == r ? left.lastPathComponent < right.lastPathComponent : l > r
        }
        var count = 0
        var bytes = 0
        for file in ordered {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if count < countLimit && size <= byteLimit - bytes {
                count += 1
                bytes += size
            } else {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
