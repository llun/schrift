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
        for size in [DynamicTypeSize.xSmall, .medium, .large, .xLarge, .xxLarge, .xxxLarge] {
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
