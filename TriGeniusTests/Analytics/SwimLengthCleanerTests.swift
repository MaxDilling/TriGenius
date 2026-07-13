import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the swim length cleaner. Expected values hand-computed
// from the merge algorithm (tRef/sRef medians, TSSConstants thresholds). Update
// alongside Analytics/SwimLengthCleaner.swift.

// 25 m pool. B (8 s → 3.13 m/s > 1.3 ceiling) is a fragment and merges into A,
// the shorter neighbour: sRef = median(20, 22) = 21 (B excluded as impossible).
private let fragmented = [
    SwimLength(durationSeconds: 30, strokes: 20, distanceMeters: 25),
    SwimLength(durationSeconds: 8, strokes: 5, distanceMeters: 25),
    SwimLength(durationSeconds: 35, strokes: 22, distanceMeters: 25)
]

@Test func clean_mergesFragmentIntoShorterNeighbour() {
    #expect(SwimLengthCleaner.clean(fragmented, poolLengthMeters: 25)?.lengths == [
        SwimCleanResult.Length(durationSeconds: 38, strokes: 25, distanceMeters: 25, absorbedFragment: true),
        SwimCleanResult.Length(durationSeconds: 35, strokes: 22, distanceMeters: 25, absorbedFragment: false)
    ])
}

@Test func clean_conservesSwimTimeAcrossMerges() {
    #expect(SwimLengthCleaner.clean(fragmented, poolLengthMeters: 25)?.swimTimeSeconds == 73)
}

@Test func clean_countIsCleanedLengthCount() {
    #expect(SwimLengthCleaner.clean(fragmented, poolLengthMeters: 25)?.cleanedLengthCount == 2)
}

@Test func clean_plausibleLengthsUntouched() {
    let lengths = [
        SwimLength(durationSeconds: 30, strokes: 20, distanceMeters: 25),
        SwimLength(durationSeconds: 31, strokes: 21, distanceMeters: 25),
        SwimLength(durationSeconds: 29, strokes: 19, distanceMeters: 25)
    ]
    #expect(SwimLengthCleaner.clean(lengths, poolLengthMeters: 25)?.lengths == [
        SwimCleanResult.Length(durationSeconds: 30, strokes: 20, distanceMeters: 25, absorbedFragment: false),
        SwimCleanResult.Length(durationSeconds: 31, strokes: 21, distanceMeters: 25, absorbedFragment: false),
        SwimCleanResult.Length(durationSeconds: 29, strokes: 19, distanceMeters: 25, absorbedFragment: false)
    ])
}

@Test func clean_noLengths_isNil() {
    #expect(SwimLengthCleaner.clean([], poolLengthMeters: 25) == nil)
}

@Test func clean_noPoolLength_isNil() {
    #expect(SwimLengthCleaner.clean(fragmented, poolLengthMeters: 0) == nil)
}
