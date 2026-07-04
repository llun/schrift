import UIKit
import XCTest

@testable import Schrift

@MainActor
final class InteractivePopGestureTests: XCTestCase {

    // MARK: - shouldAllowInteractivePop

    func testShouldAllowInteractivePopRefusesEmptyAndRootOnlyStacks() {
        XCTAssertFalse(shouldAllowInteractivePop(stackDepth: 0))
        XCTAssertFalse(shouldAllowInteractivePop(stackDepth: 1))
    }

    func testShouldAllowInteractivePopAllowsStacksWithPushedScreens() {
        XCTAssertTrue(shouldAllowInteractivePop(stackDepth: 2))
        XCTAssertTrue(shouldAllowInteractivePop(stackDepth: 5))
    }

    // MARK: - InteractivePopGestureDelegate

    func testDelegateRefusesGestureWhileNavigationStackIsAtRoot() {
        let navigationController = UINavigationController(rootViewController: UIViewController())
        let delegate = InteractivePopGestureDelegate()
        delegate.navigationController = navigationController

        XCTAssertFalse(delegate.gestureRecognizerShouldBegin(UIScreenEdgePanGestureRecognizer()))
    }

    func testDelegateAllowsGestureOnceStackHasScreenToPop() {
        let navigationController = UINavigationController(rootViewController: UIViewController())
        navigationController.pushViewController(UIViewController(), animated: false)
        let delegate = InteractivePopGestureDelegate()
        delegate.navigationController = navigationController

        XCTAssertTrue(delegate.gestureRecognizerShouldBegin(UIScreenEdgePanGestureRecognizer()))
    }

    func testDelegateRefusesGestureWhenNavigationControllerIsGone() {
        let delegate = InteractivePopGestureDelegate()

        XCTAssertFalse(delegate.gestureRecognizerShouldBegin(UIScreenEdgePanGestureRecognizer()))
    }

    // MARK: - InteractivePopGestureRestorerViewController

    func testRestorerTakesOverPopGestureDelegateWhenAttachedInsideNavigationController() {
        let root = UIViewController()
        let navigationController = UINavigationController(rootViewController: root)
        let restorer = InteractivePopGestureRestorerViewController()

        root.addChild(restorer)
        root.view.addSubview(restorer.view)
        restorer.didMove(toParent: root)

        XCTAssertTrue(navigationController.interactivePopGestureRecognizer?.delegate === restorer.popDelegate)
        XCTAssertTrue(restorer.popDelegate.navigationController === navigationController)
    }

    func testRestorerLeavesGestureAloneOutsideNavigationController() {
        let parent = UIViewController()
        let restorer = InteractivePopGestureRestorerViewController()

        parent.addChild(restorer)
        parent.view.addSubview(restorer.view)
        restorer.didMove(toParent: parent)

        XCTAssertNil(restorer.popDelegate.navigationController)
    }
}
