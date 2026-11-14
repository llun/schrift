import XCTest

@testable import Schrift

final class NativeInlinePickerTests: XCTestCase {
    private func block(
        node: String = "paragraph",
        runs: [InlineRun],
        isOpaque: Bool = false
    ) -> BlockSnapshot {
        BlockSnapshot(id: "block-1", node: node, props: [], runs: runs, isOpaque: isOpaque)
    }

    private func utf16Length(_ runs: [InlineRun]) -> Int {
        runs.reduce(0) { $0 + $1.text.utf16.count }
    }

    private func makeAccess(
        userID: UUID? = UUID(),
        fullName: String? = nil,
        shortName: String? = nil,
        email: String? = nil,
        role: DocumentRole = .editor,
        maxRole: DocumentRole? = nil,
        includeUser: Bool = true
    ) -> DocumentAccess {
        let user =
            includeUser
            ? ShareUser(id: userID, email: email, fullName: fullName, shortName: shortName)
            : nil
        return DocumentAccess(id: UUID(), user: user, team: nil, role: role, maxRole: maxRole)
    }

    // MARK: - Block eligibility & bounds

    func testEditableInlineBlockNodesAcceptTriggersWhileCodeAndOpaqueBlocksReject() {
        let editableNodes = [
            "paragraph", "heading", "bulletListItem", "numberedListItem",
            "checkListItem", "quote", "callout", "toggleListItem", "tableParagraph",
        ]
        for node in editableNodes {
            let b = block(node: node, runs: [InlineRun("[[sp")])
            XCTAssertEqual(
                nativeInlineTrigger(in: b, caret: 4, slashSessionAnchor: nil),
                NativeInlineTrigger(kind: .pageLink, range: 0..<4, query: "sp"),
                "Expected \(node) to allow inline triggers")
        }

        for blockedNode in ["codeBlock", "divider", "pageBreak", "image"] {
            let b = block(node: blockedNode, runs: [InlineRun("[[sp")])
            XCTAssertNil(nativeInlineTrigger(in: b, caret: 4, slashSessionAnchor: nil), "\(blockedNode) must reject")
        }

        let opaque = block(node: "paragraph", runs: [InlineRun("[[sp")], isOpaque: true)
        XCTAssertNil(nativeInlineTrigger(in: opaque, caret: 4, slashSessionAnchor: nil))
    }

    func testOutOfRangeCaretsReturnNil() {
        let b = block(runs: [InlineRun("[[sp")])
        XCTAssertNil(nativeInlineTrigger(in: b, caret: -1, slashSessionAnchor: nil))
        XCTAssertNil(nativeInlineTrigger(in: b, caret: 5, slashSessionAnchor: nil))
    }

    // MARK: - Run boundaries, marks, and barriers

    func testNonBlockingFormattingRunsDoNotSplitTrigger() {
        let runs = [
            InlineRun("[[", marks: [("bold", "{}")]),
            InlineRun("Q3 ", marks: [("italic", "{}")]),
            InlineRun("Plan", marks: [("textColor", #"{"stringValue":"blue"}"#)]),
        ]
        let trigger = nativeInlineTrigger(in: block(runs: runs), caret: utf16Length(runs), slashSessionAnchor: nil)
        XCTAssertEqual(trigger, NativeInlineTrigger(kind: .pageLink, range: 0..<9, query: "Q3 Plan"))
    }

    func testCodeAndLinkMarksActAsHardBarriers() {
        // Inside a code or link run.
        XCTAssertNil(
            nativeInlineTrigger(
                in: block(runs: [InlineRun("[[spec", marks: [("code", "{}")])]),
                caret: 6, slashSessionAnchor: nil))
        XCTAssertNil(
            nativeInlineTrigger(
                in: block(runs: [InlineRun("@ada", marks: [("link", #"{"href":"https://docs.example"}"#)])]),
                caret: 4, slashSessionAnchor: nil))

        // Opener before a code/link run with query entering the barrier run.
        XCTAssertNil(
            nativeInlineTrigger(
                in: block(runs: [InlineRun("[["), InlineRun("spec", marks: [("code", "{}")])]),
                caret: 6, slashSessionAnchor: nil))
        XCTAssertNil(
            nativeInlineTrigger(
                in: block(runs: [
                    InlineRun("@"), InlineRun("ada", marks: [("link", #"{"href":"https://docs.example"}"#)]),
                ]),
                caret: 4, slashSessionAnchor: nil))

        // Opener cleanly after a code/link barrier succeeds.
        let afterCode = [InlineRun("x", marks: [("code", "{}")]), InlineRun(" [[spec")]
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: afterCode), caret: utf16Length(afterCode), slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .pageLink, range: 2..<8, query: "spec"))

        let afterLink = [
            InlineRun("site", marks: [("link", #"{"href":"https://docs.example"}"#)]),
            InlineRun(" @ada"),
        ]
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: afterLink), caret: utf16Length(afterLink), slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .mention, range: 5..<9, query: "ada"))
    }

    func testActiveCodeOrLinkTypingMarksRejectSlashSessionAtBoundary() {
        let trailingCode = [InlineRun("code", marks: [("code", "{}")])]
        XCTAssertNil(nativeInlineTrigger(in: block(runs: trailingCode), caret: 4, slashSessionAnchor: 4))

        // Link is non-inclusive at its trailing edge, so a slash session after a link is outside the link.
        let linkMark = ("link", #"{"href":"https://docs.example"}"#)
        let trailingLink = [InlineRun("site", marks: [linkMark])]
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: trailingLink), caret: 4, slashSessionAnchor: 4),
            NativeInlineTrigger(kind: .slashPageLink, range: 4..<4, query: ""))

        // Inside two adjacent link runs with the same href, typing mark is active link -> reject.
        let middleOfLink = [InlineRun("si", marks: [linkMark]), InlineRun("te", marks: [linkMark])]
        XCTAssertNil(nativeInlineTrigger(in: block(runs: middleOfLink), caret: 2, slashSessionAnchor: 2))

        // Explicit activeMarks at caret rejects triggers.
        XCTAssertNil(
            nativeInlineTrigger(
                in: block(runs: [InlineRun("hello ")]),
                caret: 6,
                slashSessionAnchor: 6,
                activeMarks: [TextMark(key: "code", valueJSON: "{}")]))
    }

    func testInlineObjectAndLineBreakBarriersIsolateTriggers() {
        let chip = InlineRun(inlineObject: .mention(userID: "u1", fullName: "Ada"))
        let acrossChip = [InlineRun("[["), chip, InlineRun("Spec")]
        XCTAssertNil(
            nativeInlineTrigger(in: block(runs: acrossChip), caret: utf16Length(acrossChip), slashSessionAnchor: nil))

        let pageAfterChip = [chip, InlineRun("[[Spec")]
        XCTAssertEqual(
            nativeInlineTrigger(
                in: block(runs: pageAfterChip), caret: utf16Length(pageAfterChip), slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .pageLink, range: 1..<7, query: "Spec"))

        // Line breaks (\n and \u{2028}) isolate triggers.
        XCTAssertNil(nativeInlineTrigger(in: block(runs: [InlineRun("[[\nSpec")]), caret: 7, slashSessionAnchor: nil))
        XCTAssertNil(
            nativeInlineTrigger(in: block(runs: [InlineRun("@a\u{2028}da")]), caret: 5, slashSessionAnchor: nil))
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun("line1\n@ada")]), caret: 10, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .mention, range: 6..<10, query: "ada"))
    }

    // MARK: - `[[`, slash page link, and `@` trigger rules

    func testPageLinkNestedBracketsPunctuationClosedBracketsAndWhitespace() {
        // `[[[foo` anchors at inner pair (offset 1), leaving outer `[` untouched.
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun("[[[foo")]), caret: 6, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .pageLink, range: 1..<6, query: "foo"))
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun("[[[")]), caret: 3, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .pageLink, range: 1..<3, query: ""))

        // Punctuation before `[[` is allowed.
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun("([[Spec")]), caret: 7, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .pageLink, range: 1..<7, query: "Spec"))

        // Single `]` inside title does not close, while `]]` closes the opener.
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun("[[Notes [draft]")]), caret: 15, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .pageLink, range: 0..<15, query: "Notes [draft]"))
        XCTAssertNil(
            nativeInlineTrigger(in: block(runs: [InlineRun("[[Spec]] more")]), caret: 13, slashSessionAnchor: nil))
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun("[[Spec]] [[Plan")]), caret: 15, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .pageLink, range: 9..<15, query: "Plan"))

        // Leading whitespace rejects `[[ `.
        XCTAssertNil(nativeInlineTrigger(in: block(runs: [InlineRun("[[ ")]), caret: 3, slashSessionAnchor: nil))
        XCTAssertNil(nativeInlineTrigger(in: block(runs: [InlineRun("[[ spec")]), caret: 7, slashSessionAnchor: nil))

        // UTF-16 offset accounting with emoji.
        let emojiText = "😀 [[ré"
        XCTAssertEqual(
            nativeInlineTrigger(
                in: block(runs: [InlineRun(emojiText)]), caret: (emojiText as NSString).length, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .pageLink, range: 3..<7, query: "ré"))
    }

    func testMentionBoundaryLeadingWhitespaceAndScanCap() {
        // Start of block, space, tab, NBSP, and inline chip all allow `@`.
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun("@ada")]), caret: 4, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .mention, range: 0..<4, query: "ada"))
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun("cc @ada")]), caret: 7, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .mention, range: 3..<7, query: "ada"))
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun("\t@ada")]), caret: 5, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .mention, range: 1..<5, query: "ada"))
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun("\u{00A0}@ada")]), caret: 5, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .mention, range: 1..<5, query: "ada"))

        let chip = InlineRun(
            inlineObject: .interlink(docID: "1", blockID: "", title: "Doc", disabled: false, trigger: "/"))
        let afterChip = [chip, InlineRun("@ada")]
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: afterChip), caret: utf16Length(afterChip), slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .mention, range: 1..<5, query: "ada"))

        // Email / word-attached / emoji-attached `@` never triggers.
        XCTAssertNil(
            nativeInlineTrigger(in: block(runs: [InlineRun("user@example.com")]), caret: 16, slashSessionAnchor: nil))
        XCTAssertNil(nativeInlineTrigger(in: block(runs: [InlineRun("foo@bar")]), caret: 7, slashSessionAnchor: nil))
        XCTAssertNil(nativeInlineTrigger(in: block(runs: [InlineRun("😀@ada")]), caret: 6, slashSessionAnchor: nil))

        // Leading whitespace (`Meet @ 5pm`) rejects immediately.
        XCTAssertNil(
            nativeInlineTrigger(in: block(runs: [InlineRun("Meet @ 5pm")]), caret: 10, slashSessionAnchor: nil))
        XCTAssertNil(nativeInlineTrigger(in: block(runs: [InlineRun("@ ")]), caret: 2, slashSessionAnchor: nil))

        // 64 UTF-16 unit scan cap.
        let atCap = "@" + String(repeating: "a", count: 63)
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun(atCap)]), caret: 64, slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .mention, range: 0..<64, query: String(repeating: "a", count: 63)))
        let overCap = "@" + String(repeating: "a", count: 64)
        XCTAssertNil(nativeInlineTrigger(in: block(runs: [InlineRun(overCap)]), caret: 65, slashSessionAnchor: nil))
    }

    func testPrecedenceBetweenMentionPageLinkAndSlashSession() {
        // Larger anchor wins between `[[` and `@`.
        let pageAfterMention = "@alice see [[Spec"
        XCTAssertEqual(
            nativeInlineTrigger(
                in: block(runs: [InlineRun(pageAfterMention)]),
                caret: (pageAfterMention as NSString).length,
                slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .pageLink, range: 11..<17, query: "Spec"))

        let mentionAfterPage = "[[unclosed @alice"
        XCTAssertEqual(
            nativeInlineTrigger(
                in: block(runs: [InlineRun(mentionAfterPage)]),
                caret: (mentionAfterPage as NSString).length,
                slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .mention, range: 11..<17, query: "alice"))

        // Invalid `@` inside `[[` query still leaves `[[` active.
        let emailInPage = "[[foo@bar"
        XCTAssertEqual(
            nativeInlineTrigger(
                in: block(runs: [InlineRun(emailInPage)]),
                caret: (emailInPage as NSString).length,
                slashSessionAnchor: nil),
            NativeInlineTrigger(kind: .pageLink, range: 0..<9, query: "foo@bar"))

        // Explicit slash session takes range `anchor..<caret` and rejects if caret moves before anchor.
        XCTAssertEqual(
            nativeInlineTrigger(in: block(runs: [InlineRun("See Plan")]), caret: 8, slashSessionAnchor: 4),
            NativeInlineTrigger(kind: .slashPageLink, range: 4..<8, query: "Plan"))
        XCTAssertNil(nativeInlineTrigger(in: block(runs: [InlineRun("See Plan")]), caret: 3, slashSessionAnchor: 4))
    }

    func testRunawayProseAutoCloseRequiresWhitespaceEmptyAndNotLoading() {
        XCTAssertFalse(shouldAutoCloseInlinePicker(query: "zzz", matchCount: 0))
        XCTAssertFalse(shouldAutoCloseInlinePicker(query: "Ada Love", matchCount: 1))
        XCTAssertFalse(shouldAutoCloseInlinePicker(query: "nobody here", matchCount: 0, isLoading: true))
        XCTAssertTrue(shouldAutoCloseInlinePicker(query: "nobody here", matchCount: 0, isLoading: false))
    }

    // MARK: - Mention candidate filtering & ranking

    func testMentionCandidatesFilterReadersTeamsMissingIDsAndDeduplicateWithLabelFallback() {
        let adaID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let bobID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        let carolID = UUID(uuidString: "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC")!
        let daveID = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!
        let readerID = UUID(uuidString: "EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE")!
        let overriddenID = UUID(uuidString: "FFFFFFFF-FFFF-4FFF-8FFF-FFFFFFFFFFFF")!
        let promotedID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

        let accesses: [DocumentAccess] = [
            // Valid with fullName + lowercase UUID.
            makeAccess(
                userID: adaID, fullName: "Ada Lovelace", shortName: "Ada", email: "ada@example.com", role: .owner),
            // Duplicate user ID -> ignored.
            makeAccess(userID: adaID, fullName: "Ada Duplicate", role: .editor),
            // Fallback to shortName when fullName is nil/blank.
            makeAccess(
                userID: bobID, fullName: "   ", shortName: "Bob", email: "bob@example.com", role: .administrator),
            // Fallback to email when both fullName and shortName are nil/empty.
            makeAccess(userID: carolID, fullName: nil, shortName: "", email: "carol@example.com", role: .commenter),
            // All label fields empty -> dropped.
            makeAccess(userID: daveID, fullName: " ", shortName: nil, email: "", role: .editor),
            // Direct reader -> excluded.
            makeAccess(userID: readerID, fullName: "Reader User", role: .reader),
            // role == .editor overridden by maxRole == .reader -> excluded.
            makeAccess(userID: overriddenID, fullName: "Overridden User", role: .editor, maxRole: .reader),
            // role == .reader overridden by maxRole == .editor -> included.
            makeAccess(userID: promotedID, fullName: "Promoted User", role: .reader, maxRole: .editor),
            // Team-only row (user == nil) and user without id -> excluded.
            makeAccess(includeUser: false),
            makeAccess(userID: nil, fullName: "No ID", role: .editor),
        ]

        let candidates = mentionCandidates(from: accesses)
        XCTAssertEqual(
            candidates,
            [
                MentionCandidate(
                    userID: adaID.uuidString.lowercased(),
                    fullName: "Ada Lovelace",
                    shortName: "Ada",
                    email: "ada@example.com"),
                MentionCandidate(
                    userID: bobID.uuidString.lowercased(),
                    fullName: "Bob",
                    shortName: "Bob",
                    email: "bob@example.com"),
                MentionCandidate(
                    userID: carolID.uuidString.lowercased(),
                    fullName: "carol@example.com",
                    shortName: nil,
                    email: "carol@example.com"),
                MentionCandidate(
                    userID: promotedID.uuidString.lowercased(),
                    fullName: "Promoted User",
                    shortName: nil,
                    email: nil),
            ])
    }

    func testRankedMentionCandidatesOrderDiacriticsAndWords() {
        let prefix = MentionCandidate(userID: "1", fullName: "René Dupont", shortName: "René", email: nil)
        let wordPrefix = MentionCandidate(userID: "2", fullName: "Jean Rene", shortName: nil, email: nil)
        let containsA = MentionCandidate(userID: "3", fullName: "Claire Moreau-Rene", shortName: nil, email: nil)
        let containsB = MentionCandidate(userID: "4", fullName: "Irene Adler", shortName: nil, email: nil)
        let unmatched = MentionCandidate(userID: "5", fullName: "Ada Lovelace", shortName: nil, email: nil)

        let ranked = rankedMentionCandidates(
            query: "rene",
            candidates: [containsB, unmatched, containsA, wordPrefix, prefix])
        XCTAssertEqual(ranked.map(\.userID), ["1", "2", "3", "4"])

        // Multi-word matching folds diacritics and ignores case.
        XCTAssertEqual(
            rankedMentionCandidates(query: "ADA love", candidates: [prefix, unmatched]).map(\.userID),
            ["5"])

        // Empty query sorts alphabetically and respects limit.
        let emptyRanked = rankedMentionCandidates(
            query: "",
            candidates: [prefix, unmatched, containsB],
            limit: 2)
        XCTAssertEqual(emptyRanked.map(\.userID), ["5", "4"])
    }

    // MARK: - Key claiming & picker state

    func testInlinePickerClaimsAndHighlightState() {
        XCTAssertTrue(inlinePickerClaims(.escape, matchCount: 0))
        XCTAssertTrue(inlinePickerClaims(.escape, matchCount: 2))
        XCTAssertFalse(inlinePickerClaims(.up, matchCount: 0))
        XCTAssertFalse(inlinePickerClaims(.down, matchCount: 0))
        XCTAssertTrue(inlinePickerClaims(.up, matchCount: 2))
        XCTAssertTrue(inlinePickerClaims(.down, matchCount: 1))

        XCTAssertEqual(movedInlinePickerHighlight(0, by: .up, count: 3), 2)
        XCTAssertEqual(movedInlinePickerHighlight(2, by: .down, count: 3), 0)

        let ada = MentionCandidate(userID: "1", fullName: "Ada", shortName: nil, email: nil)
        let loading = NativeMentionPickerState(query: "a", isLoading: true, matches: [ada], highlightedIndex: 0)
        XCTAssertNil(loading.highlighted)

        let loaded = NativeMentionPickerState(query: "a", isLoading: false, matches: [ada], highlightedIndex: 0)
        XCTAssertEqual(loaded.highlighted, ada)
    }
}
