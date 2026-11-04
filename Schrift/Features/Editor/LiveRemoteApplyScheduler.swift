import QuartzCore

/// One pending frame callback per editor. Tests can deliver a frame explicitly.
@MainActor
protocol LiveRemoteApplyScheduling: AnyObject {
    func schedule(_ apply: @escaping @MainActor () -> Void)
    func cancel()
}

/// A one-shot display link, including while the run loop is tracking a gesture.
@MainActor
final class DisplayLinkRemoteApplyScheduler: LiveRemoteApplyScheduling {
    private var displayLink: CADisplayLink?
    private var apply: (@MainActor () -> Void)?

    @MainActor
    private final class Target: NSObject {
        weak var scheduler: DisplayLinkRemoteApplyScheduler?

        init(scheduler: DisplayLinkRemoteApplyScheduler) {
            self.scheduler = scheduler
        }

        @objc func tick(_ link: CADisplayLink) {
            // Also stops the link if the editor/scheduler died before this frame.
            link.invalidate()
            scheduler?.fire(link)
        }
    }

    func schedule(_ apply: @escaping @MainActor () -> Void) {
        cancel()
        self.apply = apply
        let link = CADisplayLink(target: Target(scheduler: self), selector: #selector(Target.tick(_:)))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        apply = nil
    }

    private func fire(_ link: CADisplayLink) {
        guard displayLink === link else { return }
        let callback = apply
        displayLink = nil
        apply = nil
        callback?()
    }
}
