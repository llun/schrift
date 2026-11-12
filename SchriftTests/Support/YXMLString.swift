import Foundation

@testable import Schrift

/// Comparison-only port of the session-local S3 harness's XML renderer, adapted to Schrift's core.
/// Mirrors yjs 13.6.33 `YXmlFragment.toString` (yjs.cjs @7786), `YXmlElement.toString`
/// (@8063) and `YXmlText.toString` (@8401) for the captured XML nodes and attributes.
/// This renders the replica directly, independently of the production BlockNote projection.
enum YXMLString {
    static func fragment(_ doc: YDoc) -> String {
        guard let root = doc.share["document-store"] else { return "" }
        return children(of: root)
    }

    // YXmlFragment.toString (yjs.cjs @7786): visible children in list order.
    private static func children(of type: YType) -> String {
        var out = ""
        var item = type.start
        while let current = item {
            defer { item = current.right }
            guard !current.deleted else { continue }
            // A non-type child never appears in the captures: never matches yjs's output.
            guard case .type(let child) = current.content else {
                out += "<unsupported \(current.content)>"
                continue
            }
            out += node(child)
        }
        return out
    }

    private static func node(_ type: YType) -> String {
        switch type.typeRef {
        case .xmlText: return text(type)
        case .xmlElement(let name):
            // YXmlElement.toString (yjs.cjs @8063): sorted attrs and lowercase tag name.
            let attrs = type.map.filter { !$0.value.deleted }.keys.sorted().compactMap { key -> String? in
                guard let item = type.map[key], case .any(let values) = item.content, let value = values.last else {
                    return nil
                }
                return " \(key)=\"\(render(value))\""
            }.joined()
            let lower = name.lowercased()
            return "<\(lower)\(attrs)>\(children(of: type))</\(lower)>"
        default: return children(of: type)
        }
    }

    // YXmlText.toString (yjs.cjs @8401): delta runs, sorted marks and sorted mark attributes.
    private static func text(_ type: YType) -> String {
        // Build the delta: runs of text with the format attributes active over them.
        var runs: [(String, [String: Any])] = []
        var current: [String: Any] = [:]
        var units: [UInt16] = []
        func flush() {
            guard !units.isEmpty else { return }
            let s = String(decoding: units, as: UTF16.self)
            if let last = runs.last, NSDictionary(dictionary: last.1).isEqual(to: current) {
                runs[runs.count - 1].0 += s
            } else {
                runs.append((s, current))
            }
            units = []
        }
        var item = type.start
        while let it = item {
            defer { item = it.right }
            guard !it.deleted else { continue }
            switch it.content {
            case .string(let u): units += u
            case .format(let key, let valueJSON):
                flush()
                let value = try? JSONSerialization.jsonObject(with: Data(valueJSON.utf8), options: [.fragmentsAllowed])
                if value == nil || value is NSNull { current[key] = nil } else { current[key] = value }
            default:
                // Embeds and other content the captures never hold: never equal to yjs's output,
                // so an unsupported shape fails the comparison instead of silently passing.
                flush()
                runs.append(("<unsupported \(it.content)>", [:]))
            }
        }
        flush()
        return runs.map { text, attrs in
            let names = attrs.keys.sorted()
            var s = ""
            for name in names {
                s += "<\(name)"
                if let object = attrs[name] as? [String: Any] {
                    for key in object.keys.sorted() { s += " \(key)=\"\(object[key].map { "\($0)" } ?? "")\"" }
                }
                s += ">"
            }
            s += text
            for name in names.reversed() { s += "</\(name)>" }
            return s
        }.joined()
    }

    private static func render(_ value: YAnyValue) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .undefined: return "undefined"
        // JS `Array.prototype.toString` (a table cell's `colwidth`): "," between
        // elements, null and undefined empty.
        case .array(let values):
            return values.map { $0 == .null || $0 == .undefined ? "" : render($0) }.joined(separator: ",")
        // Floats and objects never appear in the captures; never match yjs's coercion.
        default: return "<unsupported \(value)>"
        }
    }
}
