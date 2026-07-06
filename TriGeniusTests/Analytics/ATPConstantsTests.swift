import Foundation
import Testing
@testable import TriGenius

// Pins the Appendix B suggested-volume table (Analytics/ATPConstants.swift). One
// #expect per checked value; update alongside the table.

@Test func suggestedVolume_matchesAppendixB() {
    let marathon = ATPConstants.suggestedVolume(for: .marathon)
    #expect(marathon.weeklyTSS == 440...990)
    #expect(marathon.targetCTL == 70...160)

    let sprint = ATPConstants.suggestedVolume(for: .triSprint)
    #expect(sprint.weeklyTSS == 290...740)
    #expect(sprint.targetCTL == 40...105)

    // Steady-state identity (Appendix B note): Weekly TSS ÷ 7 ≈ Target CTL.
    let half = ATPConstants.suggestedVolume(for: .triHalf)
    #expect(abs(half.weeklyTSS.upperBound / 7 - half.targetCTL.upperBound) < 10)
}
