// JSONString.swift
//
// One place for the recurring "encode a JSON object into a pretty, key-sorted
// string" step used when building tool/debug output.

import Foundation

extension String {
    /// Pretty-printed, key-sorted JSON for `object` (a dictionary or array),
    /// or `"{}"` if it isn't a valid JSON object or can't be encoded.
    nonisolated init(prettyJSON object: Any) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            self = "{}"
            return
        }
        self = string
    }
}
