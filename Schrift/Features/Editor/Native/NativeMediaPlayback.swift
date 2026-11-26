import AVKit
import ImageIO
import QuickLook
import UIKit
import UniformTypeIdentifiers

/// Where a media card's file comes from when it plays or previews.
enum NativeMediaSource: Equatable {
    /// A queued upload's bytes on this device (`NativeMediaUploads.localFile`).
    case local(URL)
    /// An upload on this server: downloaded through `AttachmentLoader` (the session's cookies on an
    /// origin-pinned path, its disk cache, offline included) and shown from that file. Nothing
    /// authenticating ever goes into a URL the player or QuickLook sees.
    case attachment(AttachmentDisplay)
    /// An image: `ImageLoader`'s cached file, under its origin policy (the tap is the consent).
    case image(URL)
    /// Another site's https file, requested only after this tap (the tap is the consent).
    case remote(URL)
}

/// What a tap on a media card does: video and audio play, image, file and PDF preview.
enum NativeMediaTap: Equatable {
    /// The block's inspector: nothing to show yet (no url, a peer's upload) or nothing this app shows.
    case inspector
    /// The system player.
    case play(NativeMediaSource)
    /// QuickLook; another site's file or PDF opens in the browser instead.
    case preview(NativeMediaSource)
    /// Another site's file while offline: a notice, and no request.
    case offline

    /// The tap's outcome for media block `node` holding `url`. `localFile` is its queued
    /// upload's bytes, which win: they are what the block will hold.
    static func route(node: String, url: String, serverOrigin: String, isOffline: Bool, localFile: URL?)
        -> NativeMediaTap
    {
        guard MediaBlock.nodes.contains(node) else { return .inspector }
        let plays = node == "video" || node == "audio"
        if let localFile {
            guard plays || attachmentExtensionIsPreviewable(localFile.pathExtension) else { return .inspector }
            return plays ? .play(.local(localFile)) : .preview(.local(localFile))
        }
        guard !url.isEmpty, let parsed = URL(string: url), isFetchableImageURL(parsed) else { return .inspector }
        if node == "image" { return .preview(.image(parsed)) }
        if let display = parseAttachmentLink("[](\(url))", serverOrigin: serverOrigin) {
            guard plays || attachmentIsPreviewable(display) else { return .inspector }
            return plays ? .play(.attachment(display)) : .preview(.attachment(display))
        }
        // Another site: https only (never a cleartext fetch), and nothing while offline.
        guard parsed.scheme?.lowercased() == "https" else { return .inspector }
        if isOffline { return .offline }
        return plays ? .play(.remote(parsed)) : .preview(.remote(parsed))
    }
}

/// Shows what a media card's tap asks for over the card's window: `AVPlayerViewController`
/// (controls, scrubbing, picture in picture, AirPlay) for video and audio, `QLPreviewController`
/// for the rest, or a notice saying why there is nothing to show.
@MainActor
enum NativeMediaPresenter {
    /// The player's accessibility identifier (UI tests find the presented player by it).
    static let playerIdentifier = "nativeMedia.player"

    static func show(_ tap: NativeMediaTap, from view: UIView, controls: NativeBlockControls) {
        guard let host = topViewController(of: view) else { return }
        switch tap {
        case .inspector:
            return
        case .offline:
            notice(controls.labels.mediaOffline, on: host, labels: controls.labels)
        case .play(let source):
            play(source, on: host, controls: controls)
        case .preview(.remote(let url)):
            // Another site's document: the browser, as the inspector's Open did; never fetched here.
            UIApplication.shared.open(url)
        case .preview(let source):
            Task {
                switch await resolve(source, controls: controls) {
                case .file(let file):
                    guard let top = topViewController(of: view) else { return }
                    top.present(NativeMediaPreviewController(url: file), animated: true)
                case .notice(let text):
                    notice(text, on: host, labels: controls.labels)
                }
            }
        }
    }

    private static func play(_ source: NativeMediaSource, on host: UIViewController, controls: NativeBlockControls) {
        // Playback, so sound plays with the Ring/Silent switch set to silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        let player = AVPlayerViewController()
        player.view.accessibilityIdentifier = playerIdentifier
        // Up at once: an upload's download can take a while and the player shows it is loading.
        host.present(player, animated: true)
        Task {
            switch await resolve(source, controls: controls) {
            case .file(let file):
                // No cookies to another site; the session's own reached this file through the loader.
                let asset = AVURLAsset(url: file, options: [AVURLAssetHTTPCookiesKey: [HTTPCookie]()])
                player.player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player.player?.play()
            case .notice(let text):
                player.dismiss(animated: true) { notice(text, on: host, labels: controls.labels) }
            }
        }
    }

    enum Resolution: Equatable {
        case file(URL)
        case notice(String)
    }

    /// The file to play or preview, downloading an upload or an image first when it must.
    static func resolve(_ source: NativeMediaSource, controls: NativeBlockControls) async -> Resolution {
        let labels = controls.labels
        let unavailable = Resolution.notice(controls.isOffline ? labels.mediaOffline : labels.mediaFailed)
        switch source {
        case .local(let url), .remote(let url):
            return .file(url)
        case .attachment(let display):
            guard let loader = controls.attachments else { return .notice(labels.mediaOffline) }
            // A tap after a failure is the user's retry, as on the attachment card.
            if case .failed = loader.state(for: display), !controls.isOffline {
                await loader.retry(display)
            } else {
                await loader.loadIfNeeded(display, allowsNetwork: !controls.isOffline)
            }
            guard case .cached(let file) = loader.state(for: display) else { return unavailable }
            return .file(file)
        case .image(let url):
            guard let loader = controls.sessionImages else { return .notice(labels.mediaOffline) }
            loader.approve(url)
            controls.approveExternalMedia(url.absoluteString)
            _ = await loader.loadIfNeeded(url, allowsNetwork: !controls.isOffline)
            // The cache names files by hash; QuickLook needs the type in the name.
            guard case .cached(let file) = loader.state(for: url), let data = try? Data(contentsOf: file),
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
                let staged = stage(data, fileExtension: type.preferredFilenameExtension ?? "")
            else { return unavailable }
            return .file(staged)
        }
    }

    /// Writes `data` as the one staged preview file, named for its type, replacing the last one.
    static func stage(_ data: Data, fileExtension: String) -> URL? {
        guard !fileExtension.isEmpty else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchriftMediaPreview", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        let file = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return file
        } catch {
            return nil
        }
    }

    private static func notice(_ text: String, on host: UIViewController, labels: NativeEditorLabels) {
        let alert = UIAlertController(title: nil, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: labels.mediaDismiss, style: .default))
        alert.view.accessibilityIdentifier = "nativeMedia.notice"
        (topViewController(of: host.view) ?? host).present(alert, animated: true)
    }

    private static func topViewController(of view: UIView) -> UIViewController? {
        var top = view.window?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// QuickLook over one file; it is its own data source (QuickLook holds that weakly).
private final class NativeMediaPreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    required init?(coder: NSCoder) { nil }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        url as NSURL
    }
}
