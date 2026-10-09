import XCTest

extension XCUIElement {
    /// Waits until the element reports the same non-empty frame on two reads
    /// `interval` apart, so a synthesized touch lands where the element really is.
    ///
    /// XCUITest resolves a tap's coordinates from the frame it reads just before
    /// synthesizing the touch, and "hittable" only says that point is on screen
    /// now. A control that is still moving (the reading surface re-applies its
    /// scroll anchor over several runloop turns while lazy rows realize, and a
    /// cold first launch at an accessibility text size lays out slowly) can be
    /// hittable and still be somewhere else by the time the touch arrives. The
    /// checklist flakes on CI were all the first UI test of the bundle, at the
    /// accessibility size, where the press left the switch off — consistent
    /// with this, though not proven by it. This waits for the target to settle;
    /// it never retries the gesture.
    func waitForStableFrame(timeout: TimeInterval = 5, interval: TimeInterval = 0.25) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        guard exists else { return false }
        var previous = frame
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
            guard exists else { return false }
            let current = frame
            if current == previous, !current.isEmpty { return true }
            previous = current
        }
        return false
    }
}
