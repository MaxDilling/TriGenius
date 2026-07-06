import Testing
import Foundation
@testable import TriGenius

// Pins for the compact tool-result serializer. The point of the type is clean,
// single-line output with no IEEE-754 float artifacts, so the rounding/trim and
// the NSNumber bool-vs-int disambiguation are the load-bearing cases.

@Test func compact_roundsDirtyFloatClean() {
    // 187.1 stored as Double is 187.0999999…; %.2f rounds it back to 187.1.
    #expect(String(compactJSON: ["x": (187.1 * 10).rounded() / 10]) == "{\"x\":187.1}")
}

@Test func compact_integralDoubleAsInt() {
    #expect(String(compactJSON: ["x": 120.0]) == "{\"x\":120}")
}

@Test func compact_twoDecimalPlaces() {
    #expect(String(compactJSON: ["x": 4.25]) == "{\"x\":4.25}")
}

@Test func compact_exactIntegerUntouched() {
    #expect(String(compactJSON: ["x": 1500]) == "{\"x\":1500}")
}

@Test func compact_boolNotInt() {
    // NSNumber(bool:) must serialize as a JSON boolean, not 1/0.
    #expect(String(compactJSON: ["a": true, "b": false]) == "{\"a\":true,\"b\":false}")
}

@Test func compact_nsNumberFromReparse() {
    // Re-parsed detailsJSON returns NSNumbers — the disambiguation must hold there too.
    let parsed = try! JSONSerialization.jsonObject(with: "{\"t\":187.1,\"n\":3,\"ok\":true}".data(using: .utf8)!)
    #expect(String(compactJSON: parsed) == "{\"n\":3,\"ok\":true,\"t\":187.1}")
}

@Test func compact_nullAndNesting() {
    let obj: [String: Any] = ["arr": [1, 2.5, NSNull()], "nested": ["k": "v"]]
    #expect(String(compactJSON: obj) == "{\"arr\":[1,2.5,null],\"nested\":{\"k\":\"v\"}}")
}

@Test func compact_keySortStable() {
    #expect(String(compactJSON: ["b": 1, "a": 1, "c": 1]) == "{\"a\":1,\"b\":1,\"c\":1}")
}

@Test func compact_escapesControlChars() {
    // A free-form name with a quote and newline must stay valid JSON.
    #expect(String(compactJSON: ["n": "a\"b\nc"]) == "{\"n\":\"a\\\"b\\nc\"}")
}

@Test func compact_passesUnicode() {
    #expect(String(compactJSON: ["n": "Lauf 🏃"]) == "{\"n\":\"Lauf 🏃\"}")
}
