import Foundation

/// A BlockNote 0.56 inline leaf element (`content: "none"`) modeled as a
/// 1-UTF-16-unit `\u{FFFC}` atom inside `InlineRun`.
enum NativeInlineObject: Equatable, Hashable, Sendable, Codable {
    case interlink(docID: String, blockID: String?, title: String?, disabled: Bool, trigger: String?)
    case mention(userID: String, fullName: String)
    case mentionSearch(disabled: Bool, trigger: String?)

    static let interlinkingLinkNodeName = "interlinkingLinkInline"
    static let userMentionNodeName = "userMentionInline"
    static let mentionSearchNodeName = "mentionSearchInline"

    static let nodeNames: Set<String> = [
        interlinkingLinkNodeName,
        userMentionNodeName,
        mentionSearchNodeName,
    ]

    var nodeName: String {
        switch self {
        case .interlink: Self.interlinkingLinkNodeName
        case .mention: Self.userMentionNodeName
        case .mentionSearch: Self.mentionSearchNodeName
        }
    }

    /// Reads a familiar inline leaf element from its `YType`, returning `nil`
    /// for unknown element names, elements with any child item (including
    /// format items), unreadable props, or known attributes of the wrong type.
    static func read(_ element: YType) -> NativeInlineObject? {
        guard case .xmlElement(let node) = element.typeRef, nodeNames.contains(node) else {
            return nil
        }
        guard YBlockProjection.children(of: element, includeFormats: true).isEmpty else {
            return nil
        }
        let (props, failure) = YBlockProjection.readProps(element)
        guard failure == nil else { return nil }
        return read(node: node, props: props, hasChildren: false)
    }

    /// Validates and constructs a `NativeInlineObject` from pre-read props.
    static func read(node: String, props: [ProjectedProp], hasChildren: Bool = false) -> NativeInlineObject? {
        guard !hasChildren else { return nil }
        var map: [String: YAnyValue] = [:]
        map.reserveCapacity(props.count)
        for prop in props {
            if map[prop.key] != nil { return nil }
            map[prop.key] = prop.value
        }

        func optionalString(_ key: String) -> (present: Bool, value: String?)? {
            guard let raw = map[key] else { return (false, nil) }
            guard case .string(let s) = raw else { return nil }
            return (true, s)
        }

        func optionalBool(_ key: String) -> (present: Bool, value: Bool)? {
            guard let raw = map[key] else { return (false, false) }
            guard case .bool(let b) = raw else { return nil }
            return (true, b)
        }

        switch node {
        case interlinkingLinkNodeName:
            guard let docID = optionalString("docId"),
                let blockID = optionalString("blockId"),
                let title = optionalString("title"),
                let disabled = optionalBool("disabled"),
                let trigger = optionalString("trigger")
            else { return nil }
            return .interlink(
                docID: docID.value ?? "",
                blockID: blockID.present ? blockID.value : nil,
                title: title.present ? title.value : nil,
                disabled: disabled.value,
                trigger: trigger.present ? trigger.value : nil)

        case userMentionNodeName:
            guard let userID = optionalString("userId"),
                let fullName = optionalString("fullName")
            else { return nil }
            return .mention(
                userID: userID.value ?? "",
                fullName: fullName.value ?? "")

        case mentionSearchNodeName:
            guard let disabled = optionalBool("disabled"),
                let trigger = optionalString("trigger")
            else { return nil }
            return .mentionSearch(
                disabled: disabled.value,
                trigger: trigger.present ? trigger.value : nil)

        default:
            return nil
        }
    }

    /// Plain display text used for non-editing summaries (outline, find,
    /// accessibility, chips), never written back to Yjs.
    var visibleText: String {
        visibleText()
    }

    /// Plain display text with optional live document title resolution for
    /// enabled interlinks whose `title` attribute is absent or empty.
    func visibleText(titleForDocument: (UUID) -> String? = { _ in nil }) -> String {
        switch self {
        case .interlink(let docID, _, let title, let disabled, _):
            if let title, !title.isEmpty { return title }
            if !disabled, !docID.isEmpty, let uuid = UUID(uuidString: docID),
                let resolved = titleForDocument(uuid), !resolved.isEmpty
            {
                return resolved
            }
            return docID
        case .mention(let userID, let fullName):
            let label = fullName.isEmpty ? (userID.isEmpty ? "?" : userID) : fullName
            return "@\(label)"
        case .mentionSearch(_, let trigger):
            guard let trigger, !trigger.isEmpty else { return "@" }
            return trigger
        }
    }

    /// Removes trailing `/` characters from an origin string, matching
    /// `origin.replace(/\/+$/, "")`.
    static func trimmingTrailingSlashes(_ origin: String) -> String {
        var result = origin
        while result.last == "/" {
            result.removeLast()
        }
        return result
    }

    /// ECMA-262 `encodeURIComponent`: escapes every UTF-8 byte except
    /// `A-Za-z0-9-_.!~*'()`, using uppercase hex `%XX`. Returns `nil` if `string`
    /// contains an unpaired UTF-16 surrogate.
    static func encodeURIComponent(_ string: String) -> String? {
        encodeURIComponent(utf16: Array(string.utf16))
    }

    /// UTF-16 overload of `encodeURIComponent`, returning `nil` on unpaired
    /// surrogates (`0xD800...0xDFFF`) exactly like JS `encodeURIComponent`.
    static func encodeURIComponent(utf16 units: [UInt16]) -> String? {
        var index = 0
        var scalars: [UnicodeScalar] = []
        scalars.reserveCapacity(units.count)
        while index < units.count {
            let unit = units[index]
            if (0xD800...0xDBFF).contains(unit) {
                guard index + 1 < units.count, (0xDC00...0xDFFF).contains(units[index + 1]) else {
                    return nil
                }
                let codePoint = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(units[index + 1]) - 0xDC00)
                guard let scalar = UnicodeScalar(codePoint) else { return nil }
                scalars.append(scalar)
                index += 2
            } else if (0xDC00...0xDFFF).contains(unit) {
                return nil
            } else {
                guard let scalar = UnicodeScalar(unit) else { return nil }
                scalars.append(scalar)
                index += 1
            }
        }

        let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)
        let utf8 = String(String.UnicodeScalarView(scalars)).utf8
        var encoded = [UInt8]()
        encoded.reserveCapacity(utf8.count)
        for byte in utf8 {
            if isUnescapedURIComponentByte(byte) {
                encoded.append(byte)
            } else {
                encoded.append(0x25)  // '%'
                encoded.append(hexDigits[Int(byte >> 4)])
                encoded.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// Parses a same-origin Docs URL `http(s)://<host>/docs/<uuid>[/][#blockId]`
    /// into an enabled `.interlink` node. Rejects cross-origin links, credentials,
    /// query parameters, whitespace/control characters, oversized fragments, and
    /// non-UUID doc paths.
    static func interlink(fromURLString raw: String, serverOrigin: String) -> NativeInlineObject? {
        guard !raw.isEmpty,
            !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || isControl($0) }),
            let url = URLComponents(string: raw),
            let server = URLComponents(string: serverOrigin),
            let urlScheme = url.scheme?.lowercased(), urlScheme == "http" || urlScheme == "https",
            let serverScheme = server.scheme?.lowercased(), serverScheme == urlScheme,
            let urlHost = url.host?.lowercased(), !urlHost.isEmpty,
            let serverHost = server.host?.lowercased(), !serverHost.isEmpty,
            urlHost == serverHost,
            effectivePort(url, scheme: urlScheme) == effectivePort(server, scheme: serverScheme),
            url.user == nil, url.password == nil, url.query == nil
        else { return nil }

        let basePath = trimmingTrailingSlashes(server.path)
        let prefix = basePath + "/docs/"
        var remainder = url.path
        guard remainder.hasPrefix(prefix) else { return nil }
        remainder.removeFirst(prefix.count)
        if remainder.hasSuffix("/") {
            remainder.removeLast()
        }
        guard !remainder.isEmpty, !remainder.contains("/"),
            let uuid = UUID(uuidString: remainder)
        else { return nil }

        var blockID: String?
        if let fragment = url.fragment {
            guard fragment.utf16.count <= 256,
                !fragment.unicodeScalars.contains(where: isControl)
            else { return nil }
            blockID = fragment
        }

        return .interlink(
            docID: uuid.uuidString.lowercased(),
            blockID: blockID ?? "",
            title: nil,
            disabled: false,
            trigger: "/")
    }

    private static func effectivePort(_ components: URLComponents, scheme: String) -> Int {
        components.port ?? (scheme == "https" ? 443 : 80)
    }

    private static func isControl(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    private static func isUnescapedURIComponentByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x41...0x5A,  // A-Z
            0x61...0x7A,  // a-z
            0x30...0x39,  // 0-9
            0x2D, 0x5F, 0x2E, 0x21, 0x7E, 0x2A, 0x27, 0x28, 0x29:  // -_.!~*'()
            true
        default:
            false
        }
    }
}
