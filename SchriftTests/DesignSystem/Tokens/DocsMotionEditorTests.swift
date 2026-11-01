import SwiftUI
import XCTest

@testable import Schrift

/// The editor's micro-motion rules (`DocsMotion+Editor`). Reduce Motion removes movement —
/// scale, slides, springs — and leaves either an instant change or a plain opacity crossfade;
/// it never removes the change itself.
final class DocsMotionEditorTests: XCTestCase {
    // MARK: Checklist

    func testTheCheckboxOnlySwellsWithoutReduceMotion() {
        XCTAssertTrue(DocsMotion.checklistPulses(reduceMotion: false))
        XCTAssertFalse(DocsMotion.checklistPulses(reduceMotion: true))
        XCTAssertGreaterThan(DocsMotion.checklistPulseScale, 1)
    }

    func testACompletedRowOnlySlidesAwayWithoutReduceMotion() {
        XCTAssertTrue(DocsMotion.checklistCollapseMoves(reduceMotion: false))
        XCTAssertFalse(DocsMotion.checklistCollapseMoves(reduceMotion: true))
    }

    func testTheCollapseCrossfadesUnderReduceMotion() {
        XCTAssertEqual(DocsMotion.checklistCollapseAnimation(reduceMotion: true), DocsMotion.crossfade)
        XCTAssertNotEqual(DocsMotion.checklistCollapseAnimation(reduceMotion: false), DocsMotion.crossfade)
    }

    // MARK: Save status

    func testSavingOnlyBlursIntoSavedWithoutReduceMotion() {
        XCTAssertTrue(DocsMotion.saveStatusBlurs(reduceMotion: false))
        XCTAssertFalse(DocsMotion.saveStatusBlurs(reduceMotion: true))
    }

    func testTheSaveStatusCrossfadesUnderReduceMotion() {
        XCTAssertEqual(DocsMotion.saveStatusAnimation(reduceMotion: true), DocsMotion.crossfade)
    }

    /// Autosave runs this constantly, so it stays an ease: a spring would bounce the label.
    func testTheSaveStatusAnimationIsNotASpring() {
        XCTAssertEqual(DocsMotion.saveStatusAnimation(reduceMotion: false), .easeInOut(duration: 0.25))
    }

    func testTheSavedCheckOnlyDrawsInWithoutReduceMotion() {
        XCTAssertTrue(DocsMotion.saveCheckDrawsIn(reduceMotion: false))
        XCTAssertFalse(DocsMotion.saveCheckDrawsIn(reduceMotion: true))
    }

    // MARK: Formatting bar

    func testTheFormattingBarOnlyScalesWithoutReduceMotion() {
        XCTAssertTrue(DocsMotion.formattingBarSwitchScales(reduceMotion: false))
        XCTAssertFalse(DocsMotion.formattingBarSwitchScales(reduceMotion: true))
        XCTAssertLessThan(DocsMotion.formattingBarSwitchScale, 1)
    }

    func testTheFormattingBarCrossfadesUnderReduceMotion() {
        XCTAssertEqual(DocsMotion.formattingBarSwitchAnimation(reduceMotion: true), DocsMotion.crossfade)
        XCTAssertNotEqual(DocsMotion.formattingBarSwitchAnimation(reduceMotion: false), DocsMotion.crossfade)
    }

    // MARK: Presence

    func testAnArrivingAvatarOnlySpringsWithoutReduceMotion() {
        XCTAssertTrue(DocsMotion.presenceArrivalSprings(reduceMotion: false))
        XCTAssertFalse(DocsMotion.presenceArrivalSprings(reduceMotion: true))
        XCTAssertLessThan(DocsMotion.presenceArrivalScale, 1)
    }

    func testAnArrivingAvatarFadesInUnderReduceMotion() {
        XCTAssertEqual(DocsMotion.presenceArrivalAnimation(reduceMotion: true), DocsMotion.crossfade)
        XCTAssertNotEqual(DocsMotion.presenceArrivalAnimation(reduceMotion: false), DocsMotion.crossfade)
    }
}
