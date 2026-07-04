import SwiftUI
import UIKit

/// Whether the edge-swipe back gesture may begin on a navigation stack that is
/// `stackDepth` view controllers deep. Kept as a pure free function so the rule
/// is unit-testable: the gesture must stay disabled on the root screen and while
/// a push/pop transition is in flight — beginning a pop in either state corrupts
/// the navigation controller's transition state.
func shouldAllowInteractivePop(stackDepth: Int, isTransitioning: Bool) -> Bool {
    !isTransitioning && stackDepth > 1
}

/// Replacement delegate for `UINavigationController.interactivePopGestureRecognizer`.
///
/// The navigation controller is normally its own gesture delegate and refuses the
/// interactive pop whenever the navigation bar is hidden. Schrift hides the system
/// bar on every pushed screen (each draws its own `NavBar`), which silently kills
/// swipe-back. Swapping in this delegate restores the gesture while still refusing
/// it at the root of the stack and during an in-flight push/pop transition.
@MainActor
final class InteractivePopGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var navigationController: UINavigationController?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigationController else { return false }
        return shouldAllowInteractivePop(
            stackDepth: navigationController.viewControllers.count,
            isTransitioning: navigationController.transitionCoordinator != nil)
    }
}

/// Hidden child view controller that re-points the enclosing navigation
/// controller's pop gesture at `popDelegate` once it lands in the view
/// controller hierarchy. The delegate is retained here because gesture
/// recognizers only hold their delegate weakly.
final class InteractivePopGestureRestorerViewController: UIViewController {
    let popDelegate = InteractivePopGestureDelegate()

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        restorePopGesture()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        restorePopGesture()
    }

    private func restorePopGesture() {
        guard let navigationController else { return }
        popDelegate.navigationController = navigationController
        navigationController.interactivePopGestureRecognizer?.delegate = popDelegate
    }
}

private struct InteractivePopGestureRestorer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> InteractivePopGestureRestorerViewController {
        InteractivePopGestureRestorerViewController()
    }

    func updateUIViewController(_ uiViewController: InteractivePopGestureRestorerViewController, context: Context) {}
}

extension View {
    /// Restores the system edge-swipe back gesture inside a `NavigationStack`
    /// whose navigation bar is hidden via `.toolbar(.hidden, for: .navigationBar)`.
    /// Apply once to the stack's root content; the swapped delegate then covers
    /// every screen pushed onto that stack.
    func restoresInteractivePopGesture() -> some View {
        background(InteractivePopGestureRestorer())
    }
}
