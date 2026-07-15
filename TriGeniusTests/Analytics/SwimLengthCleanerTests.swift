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
        SwimCleanResult.Length(durationSeconds: 38, strokes: 25, distanceMeters: 25, absorbedFragment: true, splitFromMerged: false),
        SwimCleanResult.Length(durationSeconds: 35, strokes: 22, distanceMeters: 25, absorbedFragment: false, splitFromMerged: false)
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
        SwimCleanResult.Length(durationSeconds: 30, strokes: 20, distanceMeters: 25, absorbedFragment: false, splitFromMerged: false),
        SwimCleanResult.Length(durationSeconds: 31, strokes: 21, distanceMeters: 25, absorbedFragment: false, splitFromMerged: false),
        SwimCleanResult.Length(durationSeconds: 29, strokes: 19, distanceMeters: 25, absorbedFragment: false, splitFromMerged: false)
    ])
}

@Test func clean_noLengths_isNil() {
    #expect(SwimLengthCleaner.clean([], poolLengthMeters: 25) == nil)
}

@Test func clean_noPoolLength_isNil() {
    #expect(SwimLengthCleaner.clean(fragmented, poolLengthMeters: 0) == nil)
}

// 25 m pool. D (60 s / 40 strokes) is ~2× A/B/C (~30 s / ~20 strokes) on both
// time and strokes — a missed wall-turn, split into two 30 s / 20-stroke pieces.
// tRef = median(30, 31, 29, 60) = 30.5; sRef = median(20, 21, 19, 40) = 20.5
// (all four pass the speed-ceiling check, so none are excluded from sRef).
private let merged = [
    SwimLength(durationSeconds: 30, strokes: 20, distanceMeters: 25),
    SwimLength(durationSeconds: 31, strokes: 21, distanceMeters: 25),
    SwimLength(durationSeconds: 29, strokes: 19, distanceMeters: 25),
    SwimLength(durationSeconds: 60, strokes: 40, distanceMeters: 25)
]

@Test func clean_splitsMergedLengthIntoTwo() {
    #expect(SwimLengthCleaner.clean(merged, poolLengthMeters: 25)?.lengths == [
        SwimCleanResult.Length(durationSeconds: 30, strokes: 20, distanceMeters: 25, absorbedFragment: false, splitFromMerged: false),
        SwimCleanResult.Length(durationSeconds: 31, strokes: 21, distanceMeters: 25, absorbedFragment: false, splitFromMerged: false),
        SwimCleanResult.Length(durationSeconds: 29, strokes: 19, distanceMeters: 25, absorbedFragment: false, splitFromMerged: false),
        SwimCleanResult.Length(durationSeconds: 30, strokes: 20, distanceMeters: 25, absorbedFragment: false, splitFromMerged: true),
        SwimCleanResult.Length(durationSeconds: 30, strokes: 20, distanceMeters: 25, absorbedFragment: false, splitFromMerged: true)
    ])
}

@Test func clean_splitConservesSwimTime() {
    #expect(SwimLengthCleaner.clean(merged, poolLengthMeters: 25)?.swimTimeSeconds == 150)
}

@Test func clean_splitIncreasesCleanedLengthCount() {
    #expect(SwimLengthCleaner.clean(merged, poolLengthMeters: 25)?.cleanedLengthCount == 5)
}

// cleanGrouped: lap 1 = [A] alone; lap 2 = the existing fragment pair [B, C].
// The shared reference (tRef = median(30, 8, 35) = 30; sRef = median(20, 22) = 21,
// B excluded as impossibly fast) is computed across both laps, but B only has C as
// a neighbour to merge into — it must never reach into lap 1's A.
@Test func cleanGrouped_neverMergesAcrossLapBoundary() {
    let lap1 = [SwimLength(durationSeconds: 30, strokes: 20, distanceMeters: 25)]
    let lap2 = [
        SwimLength(durationSeconds: 8, strokes: 5, distanceMeters: 25),
        SwimLength(durationSeconds: 35, strokes: 22, distanceMeters: 25)
    ]
    let results = SwimLengthCleaner.cleanGrouped([lap1, lap2], poolLengthMeters: 25)
    #expect(results?.count == 2)
    #expect(results?[0].lengths == [
        SwimCleanResult.Length(durationSeconds: 30, strokes: 20, distanceMeters: 25, absorbedFragment: false, splitFromMerged: false)
    ])
    #expect(results?[1].lengths == [
        SwimCleanResult.Length(durationSeconds: 43, strokes: 27, distanceMeters: 25, absorbedFragment: true, splitFromMerged: false)
    ])
}
