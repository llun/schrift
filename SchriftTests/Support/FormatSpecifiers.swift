import Foundation

/// What `String(format:)` requires of the argument a conversion consumes.
///
/// Reduced to the *kind* rather than the exact letter, because the distinction
/// that matters is the one that crashes: `%@` handed an `Int` dereferences an
/// integer as an object pointer. `%d` against `%i`, or `%f` against `%g`, are
/// interchangeable at the call site and a translator swapping one for the other
/// should not fail the build.
enum FormatArgumentKind: String, Equatable {
    case object
    case integer
    case double
    case character
    /// `%s` — a C string. Deliberately distinct from `%S` (`unichar *`): they
    /// are both pointers, but to different element types, so one read as the
    /// other is garbage rather than a harmless respelling.
    case cString
    case unicharString
    case pointer
    /// A conversion this parser doesn't recognise, **or a specifier that never
    /// reached one** — a `%` that runs off the end of the string, or into
    /// nothing a conversion character follows.
    ///
    /// Recorded rather than dropped, and that is load-bearing: dropping it let
    /// `"%d files: %0"` compare equal to `"%d files"`, so a corrupted tail
    /// vanished from the comparison. The gate this replaced *caught* that (it
    /// counted every `%`), which would have made the new one weaker.
    case unknown
    /// One position used with two different kinds inside a single string
    /// (`"%1$d … %1$@"`). Self-contradictory: the argument cannot be both, so
    /// whatever it is, one of the two uses renders garbage.
    case conflicted

    fileprivate init(conversion: Character) {
        switch conversion {
        case "@": self = .object
        case "d", "D", "i", "u", "U", "x", "X", "o", "O": self = .integer
        case "f", "F", "e", "E", "g", "G", "a", "A": self = .double
        case "c", "C": self = .character
        case "s": self = .cString
        case "S": self = .unicharString
        case "p": self = .pointer
        default: self = .unknown
        }
    }
}

/// One `%…` conversion, as the argument list sees it.
struct FormatSpecifier: Equatable {
    /// 1-based argument index: the explicit `n$` when the specifier is
    /// positional, otherwise the order the specifier appears in.
    let position: Int
    let kind: FormatArgumentKind
}

/// Every conversion in a format string, in argument terms.
///
/// Written for the localization gate, which has to answer one question: *would
/// this table's string consume the same arguments English's does?* Hence the
/// things a naive scan gets wrong —
///
/// - **`%%` is an escape**, not a conversion, and consumes no argument.
/// - **positional specifiers (`%2$@`) exist so translators can reorder**, which
///   is the whole point of them. `"%1$@ in %2$@"` and `"%2$@ 的 %1$@"` take the
///   same arguments; comparing the order they appear in would fail a correct
///   translation. Comparing *position → kind* does not.
/// - **`*` width and precision consume an argument of their own** (`"%*d"` takes
///   the width *then* the value), so each one occupies a position rather than
///   being skipped as punctuation.
/// - **a specifier that never reaches a conversion character still happened.**
///   It becomes `.unknown` at its position instead of disappearing.
func formatSpecifiers(in string: String) -> [FormatSpecifier] {
    var specifiers: [FormatSpecifier] = []
    var nextImplicitPosition = 1
    let characters = Array(string)
    var index = 0

    /// Takes the next implicit position — used for `*` arguments and for a
    /// specifier whose conversion character never arrived.
    func takeImplicitPosition() -> Int {
        defer { nextImplicitPosition += 1 }
        return nextImplicitPosition
    }

    while index < characters.count {
        guard characters[index] == "%" else {
            index += 1
            continue
        }
        index += 1

        // A trailing `%` is a specifier that never arrived.
        guard index < characters.count else {
            specifiers.append(FormatSpecifier(position: takeImplicitPosition(), kind: .unknown))
            break
        }

        // `%%` — a literal percent, consuming nothing.
        if characters[index] == "%" {
            index += 1
            continue
        }

        // [argument$] — ASCII digits only. `Int(_:)` parses no other script, so
        // accepting `Character.isNumber` would consume a full-width digit here
        // and then silently fall back to implicit numbering.
        var explicitPosition: Int?
        var scan = index
        var digits = ""
        while scan < characters.count, characters[scan].isASCII, characters[scan].isNumber {
            digits.append(characters[scan])
            scan += 1
        }
        if !digits.isEmpty, scan < characters.count, characters[scan] == "$",
            let parsed = Int(digits), parsed >= 1
        {
            explicitPosition = parsed
            index = scan + 1
        }

        // [flags]
        while index < characters.count, "-+ #0'".contains(characters[index]) { index += 1 }
        // [width] and [.precision] — `*` takes its value from an argument.
        var starPositions: [Int] = []
        while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
        if index < characters.count, characters[index] == "*" {
            starPositions.append(takeImplicitPosition())
            index += 1
        }
        if index < characters.count, characters[index] == "." {
            index += 1
            while index < characters.count, characters[index].isASCII, characters[index].isNumber { index += 1 }
            if index < characters.count, characters[index] == "*" {
                starPositions.append(takeImplicitPosition())
                index += 1
            }
        }
        // A `*` argument is an `int` and is passed before the value it sizes.
        for position in starPositions {
            specifiers.append(FormatSpecifier(position: position, kind: .integer))
        }

        // [length]
        for modifier in ["hh", "ll", "h", "l", "q", "L", "z", "j", "t"] {
            let end = index + modifier.count
            if end <= characters.count, String(characters[index..<end]) == modifier {
                index = end
                break
            }
        }

        // The conversion character never arrived — a truncated or malformed
        // specifier. It is still evidence, so record it.
        guard index < characters.count else {
            specifiers.append(FormatSpecifier(position: explicitPosition ?? takeImplicitPosition(), kind: .unknown))
            break
        }

        let position = explicitPosition ?? takeImplicitPosition()
        specifiers.append(FormatSpecifier(position: position, kind: FormatArgumentKind(conversion: characters[index])))
        index += 1
    }

    return specifiers
}

/// The argument list a format string implies: which position takes which kind.
///
/// A dictionary, not an array, because reusing one argument twice
/// (`"%1$@ … %1$@"`) is legal and still requires exactly one argument — so a
/// translation may reference it more often than English does without changing
/// what it must be handed.
///
/// A position used with *different* kinds collapses to `.conflicted` rather
/// than to whichever came last. Last-write-wins made `"%1$d %1$@ x %2$d"`
/// indistinguishable from the correct `"%1$@ x %2$d"`, so a self-contradictory
/// string passed the gate; `String(format:)` renders it as garbage.
func formatArgumentList(of string: String) -> [Int: FormatArgumentKind] {
    var list: [Int: FormatArgumentKind] = [:]
    for specifier in formatSpecifiers(in: string) {
        switch list[specifier.position] {
        case .none:
            list[specifier.position] = specifier.kind
        case .some(.conflicted):
            break  // already contradictory; nothing later can redeem it
        case .some(let existing) where existing != specifier.kind:
            list[specifier.position] = .conflicted
        default:
            break  // same kind again — legal reuse of one argument
        }
    }
    return list
}
