import Foundation

/// Surgical text edits of the top-level keys of a JSON object. Everything outside
/// the touched key stays byte-for-byte identical.
///
/// A key that occurs more than once reads as its last occurrence, the one `JSON.parse` (and so
/// Claude Code) keeps, and is never edited: Spool does not guess which one the user meant.
public enum JSONTopLevelEditor {
    private struct Member {
        var key: String
        var keyStart: Int
        var valueStart: Int
        var valueEnd: Int
    }

    private struct Layout {
        var members: [Member]
        var open: Int
        var close: Int
    }

    public static func value(forKey key: String, in text: String) throws -> String? {
        let bytes = Array(text.utf8)
        let layout = try parse(bytes)
        guard let member = layout.members.last(where: { $0.key == key }) else { return nil }
        return String(decoding: bytes[member.valueStart..<member.valueEnd], as: UTF8.self)
    }

    public static func setting(_ rawValue: String, forKey key: String, in text: String) throws -> String {
        guard isValidJSON(Data(rawValue.utf8)) else { throw SpoolError.malformedJSON }
        let bytes = Array(text.utf8)
        let layout = try parse(bytes)
        let value = Array(rawValue.utf8)
        var out = bytes
        if let index = try onlyIndex(of: key, in: layout) {
            let member = layout.members[index]
            out.replaceSubrange(member.valueStart..<member.valueEnd, with: value)
        } else {
            let newline = Array((text.contains("\r\n") ? "\r\n" : "\n").utf8)
            let indent = indentation(bytes, layout)
            let entry = Array(encodeKey(key).utf8) + Array(": ".utf8) + value
            if let last = layout.members.last {
                // An object written on one line stays on one line.
                let inline = !bytes[layout.open..<layout.close].contains(0x0A)
                let insertion = Array(",".utf8) + (inline ? Array(" ".utf8) : newline + indent) + entry
                out.insert(contentsOf: insertion, at: last.valueEnd)
            } else {
                let body = newline + indent + entry + newline
                out.replaceSubrange((layout.open + 1)..<layout.close, with: body)
            }
        }
        return try validated(out)
    }

    public static func removing(key: String, in text: String) throws -> String {
        let bytes = Array(text.utf8)
        let layout = try parse(bytes)
        guard let index = try onlyIndex(of: key, in: layout) else { return text }
        let member = layout.members[index]
        var out = bytes
        if index + 1 < layout.members.count {
            out.removeSubrange(member.keyStart..<layout.members[index + 1].keyStart)
        } else if index > 0 {
            out.removeSubrange(layout.members[index - 1].valueEnd..<member.valueEnd)
        } else {
            out.removeSubrange((layout.open + 1)..<layout.close)
        }
        return try validated(out)
    }

    // MARK: - Internals

    /// The member holding `key`; nil when there is none. Throws when there is more than one.
    private static func onlyIndex(of key: String, in layout: Layout) throws -> Int? {
        let indices = layout.members.indices.filter { layout.members[$0].key == key }
        guard indices.count <= 1 else { throw SpoolError.duplicateKey(key) }
        return indices.first
    }

    private static func isValidJSON(_ data: Data) -> Bool {
        StrictJSON.isValid(Array(data))
    }

    private static func validated(_ bytes: [UInt8]) throws -> String {
        guard StrictJSON.isValid(bytes), bytes.first(where: { !StrictJSON.space.contains($0) }) == 0x7B else {
            throw SpoolError.malformedJSON
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func encodeKey(_ key: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(key)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The indentation of the first member that starts its own line, so a new member lines up
    /// with the object's own; two spaces when no member does.
    private static func indentation(_ bytes: [UInt8], _ layout: Layout) -> [UInt8] {
        for member in layout.members {
            var start = member.keyStart
            while start > 0, bytes[start - 1] != 0x0A {
                start -= 1
            }
            let prefix = Array(bytes[start..<member.keyStart])
            if start > 0, !prefix.isEmpty, prefix.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) { return prefix }
        }
        return Array("  ".utf8)
    }

    private static func parse(_ bytes: [UInt8]) throws -> Layout {
        guard StrictJSON.isValid(bytes) else { throw SpoolError.malformedJSON }
        guard bytes.first(where: { !StrictJSON.space.contains($0) }) == 0x7B else { throw SpoolError.notAnObject }
        var i = 0
        func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }
        func skipString() {
            i += 1
            while i < bytes.count {
                if bytes[i] == 0x5C { i += 2; continue }
                if bytes[i] == 0x22 { i += 1; return }
                i += 1
            }
        }
        func skipValue() {
            switch bytes[i] {
            case 0x22:
                skipString()
            case 0x7B, 0x5B:
                var depth = 0
                while i < bytes.count {
                    let b = bytes[i]
                    if b == 0x22 { skipString(); continue }
                    if b == 0x7B || b == 0x5B { depth += 1 }
                    if b == 0x7D || b == 0x5D { depth -= 1 }
                    i += 1
                    if depth == 0 { return }
                }
            default:
                while i < bytes.count, ![0x2C, 0x7D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
            }
        }
        skipSpace()
        let open = i
        i += 1
        var members: [Member] = []
        while true {
            skipSpace()
            guard i < bytes.count else { throw SpoolError.malformedJSON }
            if bytes[i] == 0x7D { return Layout(members: members, open: open, close: i) }
            if bytes[i] == 0x2C { i += 1; continue }
            let keyStart = i
            skipString()
            guard let key = try? JSONSerialization.jsonObject(with: Data(bytes[keyStart..<i]), options: [.fragmentsAllowed]) as? String else {
                throw SpoolError.malformedJSON
            }
            skipSpace()
            i += 1 // colon
            skipSpace()
            let valueStart = i
            skipValue()
            members.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: i))
        }
    }
}

/// Strict RFC 8259 validator (JSONSerialization tolerates trailing commas).
private struct StrictJSON {
    static let space: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
    private let b: [UInt8]
    private var i = 0

    static func isValid(_ bytes: [UInt8]) -> Bool {
        var v = StrictJSON(b: bytes)
        v.skip()
        guard v.value(depth: 0) else { return false }
        v.skip()
        return v.i == bytes.count
    }

    private init(b: [UInt8]) { self.b = b }

    private mutating func skip() {
        while i < b.count, Self.space.contains(b[i]) { i += 1 }
    }

    private mutating func literal(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { return false }
        i += u.count
        return true
    }

    private mutating func value(depth: Int) -> Bool {
        guard depth < 512, i < b.count else { return false }
        switch b[i] {
        case 0x7B:
            i += 1; skip()
            if i < b.count, b[i] == 0x7D { i += 1; return true }
            while true {
                skip()
                guard string() else { return false }
                skip()
                guard i < b.count, b[i] == 0x3A else { return false }
                i += 1; skip()
                guard value(depth: depth + 1) else { return false }
                skip()
                guard i < b.count else { return false }
                if b[i] == 0x2C { i += 1; continue }
                if b[i] == 0x7D { i += 1; return true }
                return false
            }
        case 0x5B:
            i += 1; skip()
            if i < b.count, b[i] == 0x5D { i += 1; return true }
            while true {
                skip()
                guard value(depth: depth + 1) else { return false }
                skip()
                guard i < b.count else { return false }
                if b[i] == 0x2C { i += 1; continue }
                if b[i] == 0x5D { i += 1; return true }
                return false
            }
        case 0x22: return string()
        case 0x74: return literal("true")
        case 0x66: return literal("false")
        case 0x6E: return literal("null")
        default: return number()
        }
    }

    private mutating func string() -> Bool {
        guard i < b.count, b[i] == 0x22 else { return false }
        i += 1
        while i < b.count {
            let c = b[i]
            if c == 0x22 { i += 1; return true }
            if c < 0x20 { return false }
            if c == 0x5C {
                i += 1
                guard i < b.count else { return false }
                if b[i] == 0x75 {
                    guard i + 4 < b.count, b[(i + 1)...(i + 4)].allSatisfy({ Character(UnicodeScalar($0)).isHexDigit }) else { return false }
                    i += 5
                } else if "\"\\/bfnrt".utf8.contains(b[i]) { i += 1 } else { return false }
                continue
            }
            i += 1
        }
        return false
    }

    private mutating func number() -> Bool {
        func digits(_ s: inout StrictJSON) -> Bool {
            let start = s.i
            while s.i < s.b.count, (0x30...0x39).contains(s.b[s.i]) { s.i += 1 }
            return s.i > start
        }
        if i < b.count, b[i] == 0x2D { i += 1 }
        guard i < b.count else { return false }
        if b[i] == 0x30 { i += 1 } else if !digits(&self) { return false }
        if i < b.count, b[i] == 0x2E { i += 1; guard digits(&self) else { return false } }
        if i < b.count, b[i] == 0x65 || b[i] == 0x45 {
            i += 1
            if i < b.count, b[i] == 0x2B || b[i] == 0x2D { i += 1 }
            guard digits(&self) else { return false }
        }
        return true
    }
}
