import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the per-sport split (approach A). Update alongside
// Analytics/ATPSportSplit.swift.

@Test func sportSplit_evenRatio() {
    let r = ATPSportSplit.split(weeklyTSS: 100, ratio: [.bike: 1, .run: 1])
    #expect(r[.bike] == 50)
    #expect(r[.run] == 50)
}

@Test func sportSplit_floorRaisesAndRebalances() {
    // bike:swim = 3:1 of 100 → bike 75, swim 25. Swim floor 40 → swim fixed at 40,
    // bike rescaled to the remaining 60.
    let r = ATPSportSplit.split(weeklyTSS: 100, ratio: [.bike: 3, .swim: 1], floors: [.swim: 40])
    #expect(r[.swim] == 40)
    #expect(r[.bike] == 60)
}

@Test func sportSplit_emptyWhenNoVolume() {
    #expect(ATPSportSplit.split(weeklyTSS: 0, ratio: [.bike: 1]).isEmpty)
    #expect(ATPSportSplit.split(weeklyTSS: 100, ratio: [:]).isEmpty)
}
