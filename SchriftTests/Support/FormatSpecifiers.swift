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
    case cString
    case pointer
    /// A conversion this parser doesn't recognise. Kept as a distinct value
    /// rather than dropped, so an unfamiliar specifier surfaces as a mismatch
    /// instead of silently comparing equal to nothing.
    case unknown

    fileprivate init(conversion: Character) {
        switch conversion {
        case "@": self = .object
        case "d", "D", "i", "u", "U", "x", "X", "o", "O": self = .integer
        case "f", "F", "e", "E", "g", "G", "a", "A": self = .double
        case "c", "C": self = .character
        case "s", "S": self = .cString
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
/// two things a naive scan gets wrong —
///
/// - **`%%` is an escape**, not a conversion, and consumes no argument.
/// - **positional specifiers (`%2$@`) exist so translators can reorder**, which
///   is the whole point of them. `"%1$@ in %2$@"` and `"%2$@ 的 %1$@"` take the
///   same arguments; comparing the order they appear in would fail a correct
///   translation. Comparing *position → kind* does not.
func formatSpecifiers(in string: String) -> [FormatSpecifier] {
    var specifiers: [FormatSpecifier] = []
    var nextImplicitPosition = 1
    let characters = Array(string)
    var index = 0

    while index < characters.count {
        guard characters[index] == "%" else {
            index += 1
            continue
        }
        index += 1
        guard index < characters.count else { break }

        // `%%` — a literal percent, consuming nothing.
        if characters[index] == "%" {
            index += 1
            continue
        }

        // [argument$]
        var explicitPosition: Int?
        var scan = index
        var digits = ""
        while scan < characters.count, characters[scan].isNumber {
            digits.append(characters[scan])
            scan += 1
        }
        if !digits.isEmpty, scan < characters.count, characters[scan] == "$" {
            explicitPosition = Int(digits)
            index = scan + 1
        }

        // [flags] [width] [.precision] — width and precision may be `*`, which
        // takes its value from an argument; rare enough in UI copy that it is
        // deliberately not counted as one.
        while index < characters.count, "-+ #0'".contains(characters[index]) { index += 1 }
        while index < characters.count, characters[index].isNumber || characters[index] == "*" { index += 1 }
        if index < characters.count, characters[index] == "." {
            index += 1
            while index < characters.count, characters[index].isNumber || characters[index] == "*" { index += 1 }
        }

        // [length]
        for modifier in ["hh", "ll", "h", "l", "q", "L", "z", "j", "t"] {
            let end = index + modifier.count
            if end <= characters.count, String(characters[index..<end]) == modifier {
                index = end
                break
            }
        }

        guard index < characters.count else { break }
        let position = explicitPosition ?? nextImplicitPosition
        if explicitPosition == nil { nextImplicitPosition += 1 }
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
func formatArgumentList(of string: String) -> [Int: FormatArgumentKind] {
    var list: [Int: FormatArgumentKind] = [:]
    for specifier in formatSpecifiers(in: string) {
        list[specifier.position] = specifier.kind
    }
    return list
}
