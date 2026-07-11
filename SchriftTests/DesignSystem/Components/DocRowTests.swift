import XCTest

@testable import Schrift

final class DocRowTests: XCTestCase {
    func testRestrictedShowsNoIndicator() {
        XCTAssertNil(docRowReachIndicatorSystemImage(reach: .restricted))
    }

    func testAuthenticatedShowsNetworkIndicator() {
        XCTAssertEqual(docRowReachIndicatorSystemImage(reach: .authenticated), "network.badge.shield.half.filled")
    }

    func testPublicShowsGlobeIndicator() {
        XCTAssertEqual(docRowReachIndicatorSystemImage(reach: .public), "globe")
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
}
