import SwiftUI
import XCTest

@testable import Schrift

final class DocRowTests: XCTestCase {
    func testRestrictedShowsNoIndicator() {
        XCTAssertNil(docRowReachIndicatorIcon(reach: .restricted))
    }

    func testAuthenticatedShowsNetworkIndicator() {
        XCTAssertEqual(docRowReachIndicatorIcon(reach: .authenticated), .vpn_lock)
    }

    func testPublicShowsGlobeIndicator() {
        XCTAssertEqual(docRowReachIndicatorIcon(reach: .public), .public)
    }

    func testAccessibilityLabelForRestrictedUnpinnedDocument() {
        XCTAssertEqual(
            docRowAccessibilityLabel(
                title: "Q3 Planning", reach: .restricted, date: "3 days ago", pinned: false,
                pinnedLabel: "Pinned", sharedWithOrganizationLabel: "Shared with organization",
                publicLabel: "Public"),
            "Q3 Planning, 3 days ago"
        )
    }

    func testAccessibilityLabelIncludesPinned() {
        XCTAssertEqual(
            docRowAccessibilityLabel(
                title: "Q3 Planning", reach: .restricted, date: "3 days ago", pinned: true,
                pinnedLabel: "Pinned", sharedWithOrganizationLabel: "Shared with organization",
                publicLabel: "Public"),
            "Q3 Planning, Pinned, 3 days ago"
        )
    }

    func testAccessibilityLabelIncludesAuthenticatedReach() {
        XCTAssertEqual(
            docRowAccessibilityLabel(
                title: "Roadmap", reach: .authenticated, date: "Yesterday", pinned: false,
                pinnedLabel: "Pinned", sharedWithOrganizationLabel: "Shared with organization",
                publicLabel: "Public"),
            "Roadmap, Shared with organization, Yesterday"
        )
    }

    func testAccessibilityLabelIncludesPublicReach() {
        XCTAssertEqual(
            docRowAccessibilityLabel(
                title: "Public notes", reach: .public, date: "Last week", pinned: false,
                pinnedLabel: "Pinned", sharedWithOrganizationLabel: "Shared with organization",
                publicLabel: "Public"),
            "Public notes, Public, Last week"
        )
    }

    /// The glyph is `accessibilityHidden` (a Private-Use-Area character with no spoken text)
    /// and the row ignores its children, so a state carried only by that glyph and a
    /// strikethrough is invisible to VoiceOver unless it is said here.
    func testAccessibilityLabelIncludesAQueuedDeletion() {
        XCTAssertEqual(
            docRowAccessibilityLabel(
                title: "Old notes", reach: .restricted, date: "Just now", pinned: false,
                pendingDelete: true, pendingDeleteLabel: "Waiting to be deleted",
                pinnedLabel: "Pinned", sharedWithOrganizationLabel: "Shared with organization",
                publicLabel: "Public"),
            "Old notes, Waiting to be deleted, Just now"
        )
    }

    /// The two can never both be true in practice — a tombstone names a server id, a
    /// `pendingSync` row a client-minted one — but the precedence is stated rather than
    /// assumed, and a queued deletion is the more actionable fact of the two.
    func testAQueuedDeletionOutranksPendingSyncInTheLabel() {
        XCTAssertEqual(
            docRowAccessibilityLabel(
                title: "Old notes", reach: .restricted, date: "Just now", pinned: false,
                pendingSync: true, pendingSyncLabel: "On this device, waiting to sync",
                pendingDelete: true, pendingDeleteLabel: "Waiting to be deleted",
                pinnedLabel: "Pinned", sharedWithOrganizationLabel: "Shared with organization",
                publicLabel: "Public"),
            "Old notes, Waiting to be deleted, Just now"
        )
    }

    /// An empty phrase is dropped rather than producing a stray ", " in the spoken label.
    func testAQueuedDeletionWithNoPhraseIsOmitted() {
        XCTAssertEqual(
            docRowAccessibilityLabel(
                title: "Old notes", reach: .restricted, date: "Just now", pinned: false,
                pendingDelete: true, pendingDeleteLabel: "",
                pinnedLabel: "Pinned", sharedWithOrganizationLabel: "Shared with organization",
                publicLabel: "Public"),
            "Old notes, Just now"
        )
    }

    func testAccessibilityLabelOmitsEmptyDate() {
        XCTAssertEqual(
            docRowAccessibilityLabel(
                title: "Untitled document", reach: .restricted, date: "", pinned: false,
                pinnedLabel: "Pinned", sharedWithOrganizationLabel: "Shared with organization",
                publicLabel: "Public"),
            "Untitled document"
        )
    }

    func testRowKeepsTheSingleLineLayoutAtEveryNonAccessibilitySize() {
        for size in [DynamicTypeSize.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge] {
            XCTAssertFalse(rowUsesStackedLayout(size), "\(size) should keep the handoff's single-line row")
        }
    }

    /// At accessibility sizes the title and the trailing date cannot share a
    /// line: the date wins on layout priority and the title collapses to an
    /// ellipsis, which is what stacking exists to prevent.
    func testRowStacksAtAccessibilitySizes() {
        for size in [
            DynamicTypeSize.accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5,
        ] {
            XCTAssertTrue(rowUsesStackedLayout(size), "\(size) should stack the row's title above its metadata")
        }
    }
}
