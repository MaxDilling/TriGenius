// AnyValue.swift
//
// One place for the small "read a typed value out of an `Any?`/JSON dict"
// coercions that recur across the Garmin, tool, and analytics layers, plus the
// shared snake_case token normalizer. JSON dictionaries decode numbers as
// NSNumber, so that branch is checked first; the native/String branches make the
// same helpers usable for model-supplied tool arguments.

import Foundation

nonisolated enum Coerce {

    /// Double from an NSNumber / Double / numeric String; nil otherwise.
    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// Int from an NSNumber / Int / numeric String; nil otherwise.
    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        return nil
    }

    /// String from a String, or a stringified NSNumber; nil otherwise.
    static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return "\(n)" }
        return nil
    }

    /// Lowercase + snake_case a free-form token (spaces / hyphens → underscores).
    /// Returns `def` for nil. Mild canonicalization only — not fuzzy matching.
    static func token(_ value: String?, default def: String = "") -> String {
        guard let value else { return def }
        return value.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }
}
