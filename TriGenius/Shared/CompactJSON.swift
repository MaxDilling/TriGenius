// CompactJSON.swift
//
// Single-line, key-sorted JSON for LLM tool results. Unlike `String(prettyJSON:)`
// (used for the human-facing debug/copy UIs), this strips indentation and formats
// numbers under our own control so no IEEE-754 artifact (`187.09999999999999`)
// ever reaches the model — both pure token savings on every coach tool call.

import Foundation

extension String {
    /// Compact, key-sorted JSON for `object` (a dictionary or array): no
    /// whitespace, integers exact, fractional values rounded to 2 dp with trailing
    /// zeros trimmed. `"{}"` if `object` isn't a valid JSON object.
    nonisolated init(compactJSON object: Any) {
        guard JSONSerialization.isValidJSONObject(object) else { self = "{}"; return }
        self = CompactJSON.encode(object)
    }
}

enum CompactJSON {
    nonisolated static func encode(_ value: Any) -> String {
        switch value {
        case let dict as [String: Any]:
            let body = dict.keys.sorted()
                .map { "\(encodeString($0)):\(encode(dict[$0]!))" }
                .joined(separator: ",")
            return "{\(body)}"
        case let array as [Any]:
            return "[\(array.map(encode).joined(separator: ","))]"
        case is NSNull:
            return "null"
        case let number as NSNumber:
            return encodeNumber(number)
        case let string as String:
            return encodeString(string)
        default:
            return encodeString("\(value)")
        }
    }

    /// `Bool`, `Int` and `Double` all bridge to `NSNumber`, so every numeric/boolean
    /// value lands here. Booleans must be disambiguated first (the classic
    /// `JSONSerialization`/bridging trap), then exact integers pass through untouched
    /// and only true floats get the rounding/trim treatment.
    nonisolated private static func encodeNumber(_ n: NSNumber) -> String {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
        if !CFNumberIsFloatType(n) { return n.stringValue }
        var s = String(format: "%.2f", n.doubleValue)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }

    nonisolated private static func encodeString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
