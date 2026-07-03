import Foundation

// Parses the common inline markdown spans inside a block's text into BlockNote
// styled runs. Deliberately conservative: only unambiguous spans are parsed;
// anything else (including underscores, which routinely appear intra-word) is
// left as literal text so a save never mangles content.
//
// Supported: `**bold**`, `*italic*`, `` `code` ``, `~~strike~~`,
// `[text](url)`, and backslash escapes of markdown punctuation.

enum InlineMarkdown {
    static let boldValue = "{}"
    static let italicValue = "{}"
    static let codeValue = "{}"
    static let strikeValue = "{}"

    static func parse(_ text: String) -> [InlineRun] {
        let scalars = Array(text)
        var runs = scan(scalars, marks: [])
        runs = merged(runs)
        return runs
    }

    /// Scans a character array, carrying `marks` onto every literal run produced.
    private static func scan(_ chars: [Character], marks: [(key: String, valueJSON: String)]) -> [InlineRun] {
        var runs: [InlineRun] = []
        var literal = ""
        var i = 0
        let n = chars.count

        func flushLiteral() {
            if !literal.isEmpty {
                runs.append(InlineRun(literal, marks: marks))
                literal = ""
            }
        }

        while i < n {
            let c = chars[i]

            // Backslash escape of a markdown punctuation character.
            if c == "\\", i + 1 < n, isEscapable(chars[i + 1]) {
                literal.append(chars[i + 1])
                i += 2
                continue
            }

            // Inline code span: content is literal — no nested parsing and no
            // backslash escapes (backslash is a literal character inside code).
            // Require non-empty content so adjacent backticks stay literal.
            if c == "`", let close = indexOf("`", in: chars, from: i + 1, honoringEscapes: false), close > i + 1 {
                flushLiteral()
                let inner = String(chars[(i + 1)..<close])
                runs.append(InlineRun(inner, marks: marks + [("code", codeValue)]))
                i = close + 1
                continue
            }

            // Link: [text](url)
            if c == "[", let link = matchLink(chars, from: i) {
                flushLiteral()
                let hrefJSON = linkValueJSON(link.url)
                runs.append(contentsOf: scan(Array(link.text), marks: marks + [("link", hrefJSON)]))
                i = link.next
                continue
            }

            // Strong emphasis: **...**
            if c == "*", i + 1 < n, chars[i + 1] == "*",
                let close = matchDelimiter(chars, open: i, delimiter: "**")
            {
                flushLiteral()
                let inner = Array(chars[(i + 2)..<close])
                runs.append(contentsOf: scan(inner, marks: marks + [("bold", boldValue)]))
                i = close + 2
                continue
            }

            // Strikethrough: ~~...~~
            if c == "~", i + 1 < n, chars[i + 1] == "~",
                let close = matchDelimiter(chars, open: i, delimiter: "~~")
            {
                flushLiteral()
                let inner = Array(chars[(i + 2)..<close])
                runs.append(contentsOf: scan(inner, marks: marks + [("strike", strikeValue)]))
                i = close + 2
                continue
            }

            // Emphasis: *...*  (single asterisk; underscores intentionally ignored)
            if c == "*", let close = matchDelimiter(chars, open: i, delimiter: "*") {
                flushLiteral()
                let inner = Array(chars[(i + 1)..<close])
                runs.append(contentsOf: scan(inner, marks: marks + [("italic", italicValue)]))
                i = close + 1
                continue
            }

            literal.append(c)
            i += 1
        }
        flushLiteral()
        return runs
    }

    private static func isEscapable(_ c: Character) -> Bool {
        "\\`*_{}[]()#+-.!~>|".contains(c)
    }

    /// Finds `ch` at or after `from`. When `honoringEscapes` is true a backslash
    /// escapes the following character (used for link `]`/`)` scanning); code
    /// spans pass false because their content is literal.
    private static func indexOf(_ ch: Character, in chars: [Character], from: Int, honoringEscapes: Bool = true) -> Int?
    {
        var i = from
        while i < chars.count {
            if honoringEscapes, chars[i] == "\\" {
                i += 2
                continue
            }  // skip escaped char
            if chars[i] == ch { return i }
            i += 1
        }
        return nil
    }

    /// Finds the matching closing `delimiter` (length 1 or 2) for an opening at
    /// `open`, requiring non-empty, non-blank inner content. Returns the index of
    /// the first char of the closing delimiter, or nil if unmatched.
    private static func matchDelimiter(_ chars: [Character], open: Int, delimiter: String) -> Int? {
        let d = Array(delimiter)
        let len = d.count
        var i = open + len
        let n = chars.count
        while i < n {
            if chars[i] == "\\" {
                i += 2
                continue
            }
            if i + len <= n, Array(chars[i..<(i + len)]) == d {
                let inner = chars[(open + len)..<i]
                if inner.isEmpty || inner.allSatisfy({ $0 == " " }) { return nil }
                return i
            }
            i += 1
        }
        return nil
    }

    /// Matches `[text](url)` starting at `open` (a `[`). Returns text, url, and
    /// the index just past the closing paren.
    private static func matchLink(_ chars: [Character], from open: Int) -> (text: String, url: String, next: Int)? {
        let n = chars.count
        guard let closeBracket = indexOf("]", in: chars, from: open + 1) else { return nil }
        let parenOpen = closeBracket + 1
        guard parenOpen < n, chars[parenOpen] == "(" else { return nil }
        guard let closeParen = indexOf(")", in: chars, from: parenOpen + 1) else { return nil }
        let text = String(chars[(open + 1)..<closeBracket])
        let url = String(chars[(parenOpen + 1)..<closeParen])
        if text.isEmpty || url.isEmpty { return nil }
        return (text, url, closeParen + 1)
    }

    private static func linkValueJSON(_ url: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["href": url])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"href\":\"\"}"
    }

    /// Coalesces adjacent runs carrying identical marks.
    private static func merged(_ runs: [InlineRun]) -> [InlineRun] {
        var result: [InlineRun] = []
        for run in runs {
            if var last = result.last, sameMarks(last.marks, run.marks) {
                last.text += run.text
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }
        return result
    }

    private static func sameMarks(_ a: [(key: String, valueJSON: String)], _ b: [(key: String, valueJSON: String)])
        -> Bool
    {
        a.map { [$0.key, $0.valueJSON] } == b.map { [$0.key, $0.valueJSON] }
    }
}
