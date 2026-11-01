import SwiftUI
import XCTest

@testable import Schrift

final class DocsMotionTests: XCTestCase {
    func testAnimationIsNilWhenReduceMotionIsOn() {
        XCTAssertNil(DocsMotion.animation(.snappy, reduceMotion: true))
    }

    func testAnimationPassesThroughWhenReduceMotionIsOff() {
        XCTAssertEqual(DocsMotion.animation(.snappy, reduceMotion: false), .snappy)
    }

    func testTheToastOnlySlidesWithoutReduceMotion() {
        XCTAssertTrue(DocsMotion.toastSlides(reduceMotion: false))
        XCTAssertFalse(DocsMotion.toastSlides(reduceMotion: true))
    }

    func testTheToastCrossfadesInsteadOfSlidingUnderReduceMotion() {
        XCTAssertEqual(DocsMotion.toastAnimation(reduceMotion: true), DocsMotion.crossfade)
        XCTAssertEqual(DocsMotion.toastAnimation(reduceMotion: false), .snappy)
    }
}
