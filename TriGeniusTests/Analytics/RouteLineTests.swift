import Testing
@testable import TriGenius

// Pins `Analytics/RouteLine.swift`. Fixes start on the equator, where one degree
// is 6 371 000 × π / 180 = 111 194.9 m both ways; the tolerance is 10 m.

private func longitudes(_ fixes: [(Double, Double)]) -> [Double] {
    RouteLine.simplified(fixes.map { (latitude: $0.0, longitude: $0.1) }).map(\.longitude)
}

/// The middle fix lies 0.00005° = 5.56 m off the line between its neighbours.
@Test func aFixWithinTheToleranceIsDropped() {
    #expect(longitudes([(0, 0), (0.00005, 0.001), (0, 0.002)]) == [0, 0.002])
}

/// 0.0002° = 22.24 m off the line.
@Test func aFixBeyondTheToleranceIsKept() {
    #expect(longitudes([(0, 0), (0.0002, 0.001), (0, 0.002)]) == [0, 0.001, 0.002])
}

/// Out and back: the span from start to finish has no length, so the turn's
/// distance is taken to the start itself — 111.19 m.
@Test func aLoopClosingOnItsStartKeepsItsTurn() {
    #expect(longitudes([(0, 0), (0, 0.001), (0, 0)]) == [0, 0.001, 0])
}

/// The corner at 0.002 is 157 m off the first span and splits it; the fixes at
/// 0.001 and (0.001, 0.002) then sit on their halves' lines and go.
@Test func aSplitSpanIsSimplifiedOnBothSides() {
    #expect(longitudes([(0, 0), (0, 0.001), (0, 0.002), (0.001, 0.002), (0.002, 0.002)]) == [0, 0.002, 0.002])
}

/// Past the first span's end the distance is to that end, not to the line
/// extended: the overshoot at 0.003 is 111.19 m from the finish at 0.002.
@Test func anOvershootIsMeasuredToTheSpansEnd() {
    #expect(longitudes([(0, 0), (0, 0.003), (0, 0.002)]) == [0, 0.003, 0.002])
}

@Test func twoFixesAreLeftAlone() {
    #expect(longitudes([(0, 0), (0, 0.00001)]) == [0, 0.00001])
}

@Test func aLineSkipsSecondsWithoutAFix() {
    let line = RouteLine(family: .run, streams: [.latitude: [0, nil, 0.001], .longitude: [0, nil, 0.002]])
    #expect(line == RouteLine(family: .run, streams: [.latitude: [0, 0.001], .longitude: [0, 0.002]]))
}

private func line(_ fixes: [(Double, Double)]) -> RouteLine {
    RouteLine(family: .run, streams: [.latitude: fixes.map(\.0), .longitude: fixes.map(\.1)])!
}

/// Starts (0, 0), (0, 0) and (10, 10): two starts lie around (0, 0), one around
/// the trip 1 570 km away, which is left out of the box around the other two.
@Test func aTripElsewhereIsOutsideTheHomeBounds() {
    let bounds = RouteLine.homeBounds([line([(0, 0), (0, 0.1)]), line([(0, 0), (0.1, 0)]),
                                       line([(10, 10), (10, 10.1)])])
    #expect(bounds?.latitudes == 0...0.1 && bounds?.longitudes == 0...0.1)
}

/// (0, 0) has five starts within 50 km — itself twice, ±0.4° = 44.48 km and
/// −0.3° — more than any other start (four at most), so it is home; the start
/// 0.5° = 55.60 km from it is not.
@Test func homeReachesFiftyKilometresFromTheBusiestStart() {
    let bounds = RouteLine.homeBounds([line([(0, 0)]), line([(0, 0)]), line([(0, 0.4)]), line([(0, -0.4)]),
                                       line([(0, -0.3)]), line([(0, 0.5)])])
    #expect(bounds?.latitudes == 0...0 && bounds?.longitudes == -0.4...0.4)
}

@Test func noLinesHaveNoHomeBounds() {
    #expect(RouteLine.homeBounds([]) == nil)
}

@Test func aStreamWithoutAFixHasNoLine() {
    #expect(RouteLine(family: .run, streams: [.latitude: [nil], .longitude: [nil]]) == nil)
}
