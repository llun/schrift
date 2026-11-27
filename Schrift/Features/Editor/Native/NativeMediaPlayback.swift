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
    /// Any other https file, requested only after this tap (the tap is the consent). Video and audio
    /// download through `RemoteMediaClient` (no cookies, even on this server's host) and play from the
    /// file: the player is never handed a remote URL.
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
        // Neither QuickLook nor the player gets markup or a playlist (`attachmentExtensionIsPreviewable`).
        if let localFile {
            guard attachmentExtensionIsPreviewable(localFile.pathExtension) else { return .inspector }
            return plays ? .play(.local(localFile)) : .preview(.local(localFile))
        }
        guard !url.isEmpty, let parsed = URL(string: url), isFetchableImageURL(parsed) else { return .inspector }
        if node == "image" { return .preview(.image(parsed)) }
        if let display = parseAttachmentLink("[](\(url))", serverOrigin: serverOrigin) {
            guard attachmentIsPreviewable(display) else { return .inspector }
            return plays ? .play(.attachment(display)) : .preview(.attachment(display))
        }
        // Another site: https only (never a cleartext fetch), and nothing while offline.
        guard parsed.scheme?.lowercased() == "https" else { return .inspector }
        if plays, !attachmentExtensionIsPreviewable(parsed.pathExtension) { return .inspector }
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
    /// Where a preview's or a download's file is staged; a new one prunes those no preview or
    /// player still shows (`openFiles`), and all are gone at sign-out.
    static let stagingDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SchriftMediaPreview", isDirectory: true)
    /// The player on screen (or in picture in picture) and the download it waits for, so that
    /// sign-out or an account switch can stop both (`endSession`).
    private(set) static weak var activePlayer: AVPlayerViewController?
    private static var activeLoad: Task<Void, Never>?
    private static var activePlayerFile: URL?
    /// Held strongly: a player in picture in picture outlives its dismissed controller, and
    /// sign-out or the next tap must still be able to stop it.
    private static var activeAVPlayer: AVPlayer?

    /// Tests: treat `player` as the presented one, as `play` does.
    static func adoptForTesting(_ player: AVPlayerViewController) { activePlayer = player }

    /// Stops whatever is playing (on screen or in picture in picture).
    private static func stopActivePlayback() {
        activeLoad?.cancel()
        activeLoad = nil
        activeAVPlayer?.pause()
        activeAVPlayer?.replaceCurrentItem(with: nil)
        activeAVPlayer = nil
    }
    /// Staged files an open QuickLook preview still reads.
    static var openPreviewFiles = Set<URL>()

    /// Deletes staged files nothing on screen still shows.
    static func pruneStaging() {
        var open = openPreviewFiles
        if activeAVPlayer != nil, let activePlayerFile { open.insert(activePlayerFile) }
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: stagingDirectory, includingPropertiesForKeys: nil)) ?? []
        let kept = Set(open.map { $0.standardizedFileURL.path })
        for file in files where !kept.contains(file.standardizedFileURL.path) {
            try? manager.removeItem(at: file)
        }
    }

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
        // One playback at a time: a video left in picture in picture stops for the new one.
        stopActivePlayback()
        activePlayerFile = nil
        let player = AVPlayerViewController()
        player.view.accessibilityIdentifier = playerIdentifier
        // Up at once: a download can take a while and the player shows it is loading.
        host.present(player, animated: true)
        activePlayer = player
        activeLoad?.cancel()
        activeLoad = Task {
            switch await resolve(source, controls: controls) {
            case .file(let file):
                start(file, in: player)
            case .notice(let text):
                guard player.presentingViewController != nil else { return }
                player.dismiss(animated: true) { notice(text, on: host, labels: controls.labels) }
            }
        }
    }

    /// Plays local `file` in `player`, only while it is still presented: one closed during the
    /// download never starts. The asset may not reference other files or the network.
    static func start(_ file: URL, in player: AVPlayerViewController) {
        guard file.isFileURL, player.presentingViewController != nil, !player.isBeingDismissed else { return }
        let asset = AVURLAsset(
            url: file, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        if player === activePlayer { activePlayerFile = file }
        let playback = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        if player === activePlayer { activeAVPlayer = playback }
        player.player = playback
        playback.play()
    }

    /// Sign-out or an account switch: the player stops and closes, a download it waits for is
    /// cancelled, and staged copies are deleted.
    static func endSession() {
        stopActivePlayback()
        activePlayer?.player?.pause()
        activePlayer?.player?.replaceCurrentItem(with: nil)
        activePlayer?.dismiss(animated: false)
        activePlayer = nil
        activePlayerFile = nil
        openPreviewFiles = []
        try? FileManager.default.removeItem(at: stagingDirectory)
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
        case .local(let url):
            return .file(url)
        case .remote(let url):
            return await download(url, client: controls.remoteMedia, failure: unavailable)
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

    /// Another site's video or audio, as the one staged file, named for its served type (or its
    /// url's extension when the type says nothing); a playlist or markup is refused.
    static func download(_ url: URL, client: RemoteMediaClient, failure: Resolution) async -> Resolution {
        pruneStaging()
        let file = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        let mimeType: String?
        do {
            mimeType = try await client.download(url, to: file)
        } catch {
            return failure
        }
        guard let fileExtension = playableExtension(mimeType: mimeType, pathExtension: url.pathExtension) else {
            try? FileManager.default.removeItem(at: file)
            return failure
        }
        let named = file.appendingPathExtension(fileExtension)
        guard (try? FileManager.default.moveItem(at: file, to: named)) != nil else { return failure }
        return .file(named)
    }

    /// The extension a downloaded file plays under: the served type's when it is audio or video,
    /// else the url's; nil for a playlist or markup either way.
    static func playableExtension(mimeType: String?, pathExtension: String) -> String? {
        if let mimeType, mimeType.lowercased().contains("mpegurl") { return nil }
        if let served = mimeType.flatMap({ UTType(mimeType: $0) }) {
            if served.conforms(to: .playlist) || served.conforms(to: .html) || served.conforms(to: .xml) {
                return nil
            }
            if served.conforms(to: .audiovisualContent), let fileExtension = served.preferredFilenameExtension {
                return fileExtension
            }
        }
        let fileExtension = pathExtension.lowercased()
        return !fileExtension.isEmpty && attachmentExtensionIsPreviewable(fileExtension) ? fileExtension : nil
    }

    /// Writes `data` as the one staged preview file, named for its type, replacing the last one.
    static func stage(_ data: Data, fileExtension: String) -> URL? {
        guard !fileExtension.isEmpty else { return nil }
        let directory = stagingDirectory
        pruneStaging()
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
final class NativeMediaPreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let url: URL

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        dataSource = self
        NativeMediaPresenter.openPreviewFiles.insert(url)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            NativeMediaPresenter.openPreviewFiles.remove(url)
        }
    }

    required init?(coder: NSCoder) { nil }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        url as NSURL
    }
}
