import Testing
@testable import TriGenius

// Pins `Analytics/StreamPlot.swift`. Expected values are hand-computed from the
// formulas in that file; a change to the smoothing or axis model must restate
// them here in the same commit.

private let power = StreamPlot.Metric(axis: .linear(1), framing: .fromZero,
                                      zones: nil, bridgesGaps: false)
/// Running pace: speed in m/s, inverted to s/km, below 0.5 m/s = standing still.
private let runPace = StreamPlot.Metric(axis: .inverse(scale: 1000, floor: 0.5),
                                        framing: .tight, zones: nil, bridgesGaps: false)
/// Power with zone bounds — z1 ends at 150 W, z5 starts above 400 W.
private let zoned = StreamPlot.Metric(axis: .linear(1), framing: .fromZero,
                                      zones: [150, 200, 300, 400], bridgesGaps: false)

@Suite("StreamPlot bucketing")
struct StreamPlotBucketingTests {

    /// 600 bins × 50 s = 30000 s across 300 pt: 30000 × 4 / 300 / 50 = 8 bins per
    /// bucket, so 600 / 8 = 75 vertices.
    @Test func bucketSizeFollowsTheVisibleSpanPerPixel() {
        let values = [Double?](repeating: 100, count: 600)
        let segments = StreamPlot.segments(values: values, binSeconds: 50, metric: power,
                                           visibleSpan: 30000, plotWidth: 300)
        #expect(segments[0].vertices.count == 75)
    }

    /// Zoomed to a tenth of that span, the bucket floors at one stored bin —
    /// 3000 × 4 / 300 / 50 = 0.8, rounded to 0, clamped to 1 — so nothing is
    /// averaged away and every bin becomes its own vertex.
    @Test func zoomingInFloorsTheBucketAtOneStoredBin() {
        let values = [Double?](repeating: 100, count: 600)
        let segments = StreamPlot.segments(values: values, binSeconds: 50, metric: power,
                                           visibleSpan: 3000, plotWidth: 300)
        #expect(segments[0].vertices.count == 600)
    }

    /// Four 10 s bins into one bucket: mean 25, spread 10…40, centre at the
    /// midpoint of the first and last bin centres (5 and 35), and the bucket
    /// spans the bins' outer edges, 0…40.
    @Test func bucketCarriesMeanSpreadAndItsOwnSlice() {
        let segments = StreamPlot.segments(values: [10, 20, 30, 40], binSeconds: 10,
                                           metric: power, visibleSpan: 40, plotWidth: 4)
        let v = segments[0].vertices[0]
        #expect(v.mean == 25)
        #expect(v.low == 10 && v.high == 40)
        #expect(v.offset == 20)
        #expect(v.start == 0 && v.end == 40)
    }

    /// A bin without a reading is not a pause while it stays inside
    /// `holdSeconds`: the last value is held across it, so the trace stays one
    /// run. Width 20 keeps the bucket at one bin, so each bin is its own vertex.
    @Test func aShortGapIsHeldAcross() {
        let segments = StreamPlot.segments(values: [100, 100, nil, 200, 200], binSeconds: 1,
                                           metric: power, visibleSpan: 5, plotWidth: 20)
        #expect(segments.map(\.vertices.count) == [5])
        #expect(segments[0].vertices[2].mean == 100)   // the held reading
    }

    /// Past `holdSeconds` the silence is a real pause — 4 × 10 s = 40 s — so the
    /// run splits and the bins either side never share a bucket.
    @Test func aGapPastTheHoldBreaksTheTrace() {
        let values: [Double?] = [100, 100, nil, nil, nil, nil, 200, 200]
        let segments = StreamPlot.segments(values: values, binSeconds: 10, metric: power,
                                           visibleSpan: 80, plotWidth: 320)
        #expect(segments.map(\.vertices.count) == [2, 2])
    }

    /// Elevation holds across a pause however long it runs: one run, the held
    /// bin averaging in with the rest — (100 + 100 + 100 + 200 + 200) / 5.
    @Test func aBridgingMetricKeepsOneRunAcrossAGap() {
        let elevation = StreamPlot.Metric(axis: .linear(1), framing: .tight,
                                          zones: nil, bridgesGaps: true)
        let values: [Double?] = [100, 100, nil, 200, 200]
        let segments = StreamPlot.segments(values: values, binSeconds: 60, metric: elevation,
                                           visibleSpan: 300, plotWidth: 1)
        #expect(segments.count == 1)
        #expect(segments[0].vertices[0].mean == 140)
    }

    /// A pace bucket inverts: the slowest speed (2 m/s → 500 s/km) is the
    /// *highest* plot value, and `low`/`high` stay paired with their plot twins.
    @Test func paceBucketOrdersItsSpreadByPlotPosition() {
        let segments = StreamPlot.segments(values: [2, 4], binSeconds: 1, metric: runPace,
                                           visibleSpan: 2, plotWidth: 1)
        let v = segments[0].vertices[0]
        #expect(v.mean == 3)                 // mean speed, not mean pace
        #expect(v.plot == 1000.0 / 3.0)
        #expect(v.low == 4 && v.high == 2)   // fastest first, in natural units
        #expect(v.plotLow == 250 && v.plotHigh == 500)
    }

    /// Below the floor the athlete is standing still: the bin is a gap, not a
    /// very slow one, so it breaks the trace instead of plotting a huge pace.
    @Test func aStoppedPaceBinIsAGap() {
        let segments = StreamPlot.segments(values: [3, 0.1, 3], binSeconds: 1, metric: runPace,
                                           visibleSpan: 3, plotWidth: 3)
        #expect(segments.count == 2)
    }

    /// The zone is the one the bucket spent the most *time* in: three bins in
    /// zone 0 against one in zone 4.
    @Test func zoneIsTheOneHoldingMostBins() {
        let segments = StreamPlot.segments(values: [100, 100, 100, 500], binSeconds: 1,
                                           metric: zoned, visibleSpan: 4, plotWidth: 1)
        #expect(segments[0].vertices[0].zone == 0)
    }

    /// Why dominance beats the mean: three easy bins and one hard surge average
    /// to 250 W — zone 2 — but the athlete rode zone 0 for three quarters of the
    /// bucket, and that is what the trace colours.
    @Test func dominantZoneDisagreesWithTheMean() {
        let segments = StreamPlot.segments(values: [100, 100, 100, 700], binSeconds: 1,
                                           metric: zoned, visibleSpan: 4, plotWidth: 1)
        #expect(segments[0].vertices[0].mean == 250)
        #expect(segments[0].vertices[0].zone == 0)
    }

    /// An even split reads as the easier zone rather than flipping on rounding.
    @Test func aTiedBucketTakesTheLowerZone() {
        let segments = StreamPlot.segments(values: [100, 500], binSeconds: 1, metric: zoned,
                                           visibleSpan: 2, plotWidth: 1)
        #expect(segments[0].vertices[0].zone == 0)
    }
}

@Suite("StreamPlot zone runs")
struct StreamPlotZoneRunTests {

    /// One bucket per bin, zones 0,0,4,4 — two stretches, meeting where the zone
    /// changes and together covering the whole 4 s.
    @Test func adjacentBucketsOfOneZoneMergeIntoAStretch() {
        let segments = StreamPlot.segments(values: [100, 100, 500, 500], binSeconds: 1,
                                           metric: zoned, visibleSpan: 4, plotWidth: 16)
        let runs = StreamPlot.zoneRuns(of: segments)
        #expect(runs.map(\.zone) == [0, 4])
        #expect(runs[0].start == 0 && runs[0].end == 2)
        #expect(runs[1].start == 2 && runs[1].end == 4)
    }

    /// A recording gap ends the stretch even when the zone carries across it, so
    /// the ribbon never paints over a pause — 40 s of silence, past the hold.
    @Test func aStretchNeverSpansAGap() {
        let values: [Double?] = [100, nil, nil, nil, nil, 100]
        let segments = StreamPlot.segments(values: values, binSeconds: 10, metric: zoned,
                                           visibleSpan: 60, plotWidth: 240)
        let runs = StreamPlot.zoneRuns(of: segments)
        #expect(runs.map(\.zone) == [0, 0])
        #expect(runs[0].end == 10 && runs[1].start == 50)
    }

    /// Without a zone model there is nothing to colour: one stretch, no zone.
    @Test func noZoneModelIsOneStretch() {
        let segments = StreamPlot.segments(values: [100, 500], binSeconds: 1, metric: power,
                                           visibleSpan: 2, plotWidth: 8)
        let runs = StreamPlot.zoneRuns(of: segments)
        #expect(runs.count == 1)
        #expect(runs[0].zone == nil)
    }
}

@Suite("StreamPlot domain geometry")
struct StreamPlotDomainGeometryTests {

    /// A ribbon along the bottom sits above the floor whichever way the axis
    /// runs — on a reversed pace axis the floor is the *slow* end.
    @Test func fromFloorFollowsTheAxisDirection() {
        #expect(StreamPlot.Domain(lo: 0, hi: 200, reversed: false).fromFloor(0.1) == 20)
        #expect(StreamPlot.Domain(lo: 100, hi: 600, reversed: true).fromFloor(0.1) == 550)
    }
}

@Suite("StreamPlot domain")
struct StreamPlotDomainTests {

    /// An effort metric is read against zero, with 10 % headroom over the peak.
    @Test func effortFramesFromZero() {
        let domain = StreamPlot.domain(values: [100, 200, 300], metric: power)
        #expect(domain == StreamPlot.Domain(lo: 0, hi: 330, reversed: false))
    }

    /// A level metric tightens to the data, padded by the larger of 15 % of the
    /// spread (0.15 × 20 = 3) and 2 % of the peak (0.02 × 160 = 3.2) — so 3.2.
    @Test func levelFramesTight() {
        let hr = StreamPlot.Metric(axis: .linear(1), framing: .tight,
                                   zones: nil, bridgesGaps: false)
        let domain = StreamPlot.domain(values: [140, 160], metric: hr)
        #expect(domain == StreamPlot.Domain(lo: 136.8, hi: 163.2, reversed: false))
    }

    /// The pace axis reverses, and clips to the 98th percentile so one walk
    /// spike cannot squash the run. Over 3 samples (2, 2.5, 5 m/s → 500, 400,
    /// 200 s/km sorted 200/400/500) the p98 index is Int(0.98 × 2) = 1, so the
    /// 500 s/km walk is left outside the domain.
    @Test func paceReversesAndClipsTheWalkSpike() {
        let domain = StreamPlot.domain(values: [2, 2.5, 5], metric: runPace)
        #expect(domain.reversed)
        #expect(domain.hi == 400 + 0.15 * (400 - 200))
        #expect(domain.bounds == [430, 170])
    }

    /// No usable samples must not produce an empty or infinite scale.
    @Test func anEmptyStreamStillYieldsAScale() {
        #expect(StreamPlot.domain(values: [nil, nil], metric: power)
                == StreamPlot.Domain(lo: 0, hi: 1, reversed: false))
    }

    /// Mapping one metric onto another's plot: the source's midpoint lands on
    /// the target's midpoint.
    @Test func rescaleMapsDomainOntoDomain() {
        let scale = StreamPlot.Rescale(source: .init(lo: 100, hi: 300, reversed: false),
                                       target: .init(lo: 0, hi: 50, reversed: false))
        #expect(scale(200) == 25)
    }

    /// A flat source has no span to map — everything sits on the target's floor
    /// rather than dividing by zero.
    @Test func rescaleOfAFlatSourceSitsOnTheFloor() {
        let scale = StreamPlot.Rescale(source: .init(lo: 7, hi: 7, reversed: false),
                                       target: .init(lo: 10, hi: 50, reversed: false))
        #expect(scale(7) == 10)
    }
}
