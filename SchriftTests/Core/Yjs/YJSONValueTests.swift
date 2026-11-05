import XCTest

@testable import Schrift

/// `YJSONValue.equalAttrs` — the one place the delta looks inside a format value.
///
/// yjs compares two `ContentFormat` values with `===`, or lib0 `equalFlat` for two
/// objects/arrays: same key count, every value `===`. So two distinct `{}` marks
/// are equal, two `{href}` marks are equal only when their flat contents are, and
/// a nested container is never equal to another (two parses never share identity).
final class YJSONValueTests: XCTestCase {

    func testIdenticalTextIsEqual() {
        XCTAssertTrue(YJSONValue.equalAttrs("true", "true"))
        XCTAssertTrue(YJSONValue.equalAttrs("{}", "{}"))
    }

    func testObjectValuesCompareByFlatContents() {
        XCTAssertTrue(
            YJSONValue.equalAttrs(
                #"{"href":"https://example.com/"}"#, #"{"href":"https://example.com/"}"#))
        XCTAssertFalse(
            YJSONValue.equalAttrs(
                #"{"href":"https://example.com/"}"#, #"{"href":"https://other.example/"}"#))
    }

    func testObjectKeyOrderDoesNotMatter() {
        XCTAssertTrue(YJSONValue.equalAttrs(#"{"a":1,"b":2}"#, #"{"b":2,"a":1}"#))
    }

    func testDifferentObjectKeyCountsAreNotEqual() {
        XCTAssertFalse(YJSONValue.equalAttrs(#"{"a":1}"#, #"{"a":1,"b":2}"#))
    }

    func testNestedContainersAreNeverEqual() {
        // `equalFlat` compares the top level only; a nested object is compared with
        // `===`, and two parses never share identity.
        XCTAssertFalse(YJSONValue.equalAttrs(#"{"a":{"b":1}}"#, #"{"a": {"b": 1}}"#))
        XCTAssertFalse(YJSONValue.equalAttrs("[[1]]", "[ [1] ]"))
    }

    func testNumbersCompareAsDoubles() {
        XCTAssertTrue(YJSONValue.equalAttrs("1", "1.0"))
        XCTAssertFalse(YJSONValue.equalAttrs("1", "2"))
    }

    func testNullIsOnlyEqualToNull() {
        XCTAssertTrue(YJSONValue.equalAttrs(nil, nil))
        XCTAssertFalse(YJSONValue.equalAttrs(nil, "null"))
        XCTAssertFalse(YJSONValue.equalAttrs("null", nil))
    }

    func testMalformedTextIsNeverEqual() {
        XCTAssertFalse(YJSONValue.equalAttrs("{", "["))
        XCTAssertFalse(YJSONValue.equalAttrs("{}", "{"))
    }
}
