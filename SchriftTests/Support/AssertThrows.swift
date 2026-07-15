import XCTest

/// Asserts `body` throws an error equal to `expected`. The repo convention is a
/// typed do/catch (never `XCTAssertThrowsError`); this folds that shape into one
/// cross-suite helper so the byte-exact codec suites don't each hand-roll it.
/// Fails the test on the success path or on a different error.
func assertThrows<E: Error & Equatable>(
    _ expected: E,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> Void
) {
    do {
        try body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error \(error); expected \(expected)", file: file, line: line)
    }
}
