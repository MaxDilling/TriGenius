import Foundation

// MARK: - Stream plotting geometry
//
// The pure geometry behind `WorkoutStreamChart`: how many stored bins one
// on-screen bucket covers, what each bucket hides, which zone it sits in, and
// the value range the axis spans. It lives here rather than in the view because
// it is deterministic arithmetic with real edge cases — inverting pace axes,
// recording gaps, buckets straddling a zone bound — and is pinned by
// `TriGeniusTests/Analytics/StreamPlotTests.swift`.

nonisolated enum StreamPlot {

    /// How a metric's natural-unit samples reach the plot axis.
    enum Axis: Equatable {
        /// `value × factor` — power/heart rate/cadence/elevation at 1, speed at 3.6.
        case linear(Double)
        /// `scale ÷ value` — the pace kinds, drawn fastest-at-the-top. Below
        /// `floor` the athlete is standing still and the inverse blows up toward
        /// a stop, so such a sample is a gap, not a very slow one.
        case inverse(scale: Double, floor: Double)

        var isInverting: Bool { if case .inverse = self { true } else { false } }

        func display(_ value: Double) -> Double {
            switch self {
            case .linear(let factor): value * factor
            case .inverse(let scale, _): scale / value
            }
        }

        func isMoving(_ value: Double) -> Bool {
            switch self {
            case .linear: true
            case .inverse(_, let floor): value >= floor
            }
        }
    }

    /// How the axis frames its data. An inverting axis ignores this — see `domain`.
    enum Framing { case fromZero, tight }

    /// Everything about a metric the geometry needs; the view's `Kind` supplies it.
    struct Metric: Equatable {
        let axis: Axis
        let framing: Framing
        /// z1–z4 upper bounds in natural units; nil where the metric has no zone
        /// model or the threshold behind it is unknown.
        let zones: [Double]?
        /// Whether a recording gap breaks the trace or is drawn straight through.
        let bridgesGaps: Bool
    }

    /// The value range an axis spans, in plot units.
    struct Domain: Equatable {
        let lo: Double, hi: Double
        /// True for a pace axis, whose faster — numerically lower — values are
        /// drawn at the top.
        let reversed: Bool
        /// The bounds in drawing order, which is what `chartYScale(domain:)` takes.
        var bounds: [Double] { reversed ? [hi, lo] : [lo, hi] }

        /// The bottom of the plot, whichever way the axis runs.
        var floor: Double { bounds[0] }

        /// The value `fraction` of the plot's height above its floor — where a
        /// ribbon along the bottom sits, whichever way the axis runs.
        func fromFloor(_ fraction: Double) -> Double {
            bounds[0] + (bounds[1] - bounds[0]) * fraction
        }
    }

    /// Linear map of one domain onto another, so a second metric can share a plot.
    struct Rescale: Equatable {
        let source: Domain
        let target: Domain

        func callAsFunction(_ value: Double) -> Double {
            guard source.hi > source.lo else { return target.lo }
            return target.lo + (value - source.lo) / (source.hi - source.lo) * (target.hi - target.lo)
        }
    }

    /// One plotted vertex: the mean of the bins it covers, plus the raw spread
    /// that mean hides. `low`/`high` are natural units ordered by plot position
    /// (an inverting axis swaps them), so each pairs with its `plot*` twin.
    /// `start`/`end` are the bucket's own slice of the timeline — what a zone
    /// stripe behind it spans.
    struct Vertex: Identifiable, Equatable {
        let offset: Double     // bucket centre, elapsed seconds
        let start: Double, end: Double
        let mean: Double
        let plot: Double
        let low: Double, high: Double
        let plotLow: Double, plotHigh: Double
        /// 0-based zone the bucket spent the most time in; nil without a zone
        /// model. The *dominant* zone, not the zone of the mean — over a long
        /// bucket a surging effort averages into a zone barely ridden.
        let zone: Int?
        var id: Double { offset }
    }

    /// A gap-free run of the stream, already bucketed.
    struct Segment: Identifiable, Equatable {
        let id: Int
        let vertices: [Vertex]
    }

    /// One stretch the athlete held a single zone, as a slice of elapsed time.
    struct Run: Identifiable, Equatable {
        let id: Int
        let zone: Int?
        let start: Double, end: Double
    }

    /// The zone timeline: adjacent buckets of the same zone merged into one
    /// stretch. Drives the ribbon under the trace and, on a hover, the highlight
    /// of every stretch sharing that zone. Runs never span a recording gap,
    /// because each segment closes its own.
    static func zoneRuns(of segments: [Segment]) -> [Run] {
        var runs: [Run] = []
        for segment in segments {
            var open: Run?
            for vertex in segment.vertices {
                if let current = open, current.zone == vertex.zone {
                    open = Run(id: current.id, zone: current.zone,
                               start: current.start, end: vertex.end)
                } else {
                    if let current = open { runs.append(current) }
                    open = Run(id: runs.count, zone: vertex.zone,
                               start: vertex.start, end: vertex.end)
                }
            }
            if let current = open { runs.append(current) }
        }
        return runs
    }

    /// Plot width one averaging bucket covers — the whole smoothing model in one
    /// number. Finer than the eye resolves on a trace, coarse enough that an
    /// 8-hour ride stops being pixel noise.
    static let bucketPoints: Double = 4

    /// Contiguous non-gap runs — so a pause breaks the trace — each averaged down
    /// to ~one vertex per `bucketPoints` of plot width.
    ///
    /// The bucket width *is* the smoothing window, and deriving it from the span
    /// on screen per pixel settles every scale with one rule: an 8-hour ride on a
    /// phone averages minutes, the same ride in a Mac window averages far less, a
    /// 30-minute run averages seconds — and zooming in shrinks the bucket until,
    /// at the floor of one stored bin, the raw trace is back.
    static func segments(values: [Double?], binSeconds: Int, metric: Metric,
                         visibleSpan: Double, plotWidth: Double) -> [Segment] {
        let bin = Double(binSeconds)
        let bucket = max(1, Int((visibleSpan * bucketPoints / max(plotWidth, 1) / bin).rounded()))

        var segments: [Segment] = []
        var run: [(offset: Double, value: Double)] = []
        func close() {
            guard !run.isEmpty else { return }
            segments.append(Segment(id: segments.count,
                                    vertices: vertices(of: run, bucket: bucket, bin: bin,
                                                       metric: metric)))
            run = []
        }
        for (i, value) in values.enumerated() {
            if let value, metric.axis.isMoving(value) {
                run.append(((Double(i) + 0.5) * bin, value))
            } else if !metric.bridgesGaps {
                close()
            }
        }
        close()
        return segments
    }

    private static func vertices(of run: [(offset: Double, value: Double)], bucket: Int,
                                 bin: Double, metric: Metric) -> [Vertex] {
        // Bins are uniform, so counting them per zone weights by time. Reused
        // across buckets rather than allocated per vertex.
        var zoneBins = [Int](repeating: 0, count: 5)
        var vertices: [Vertex] = []
        vertices.reserveCapacity(run.count / bucket + 1)

        for first in stride(from: 0, to: run.count, by: bucket) {
            let last = min(first + bucket, run.count) - 1
            var sum = 0.0, a = Double.infinity, b = -Double.infinity
            for i in 0..<5 { zoneBins[i] = 0 }
            for i in first...last {
                let value = run[i].value
                sum += value
                a = min(a, value)
                b = max(b, value)
                // Every zone model runs on an axis that rises with intensity
                // (pace included — its bounds are speeds), so one count fits all.
                if let bounds = metric.zones { zoneBins[bounds.count { value > $0 }] += 1 }
            }
            let (pa, pb) = (metric.axis.display(a), metric.axis.display(b))
            let mean = sum / Double(last - first + 1)
            vertices.append(
                Vertex(offset: (run[first].offset + run[last].offset) / 2,
                       start: run[first].offset - bin / 2, end: run[last].offset + bin / 2,
                       mean: mean, plot: metric.axis.display(mean),
                       low: pa <= pb ? a : b, high: pa <= pb ? b : a,
                       plotLow: min(pa, pb), plotHigh: max(pa, pb),
                       zone: metric.zones == nil ? nil : dominantZone(zoneBins)))
        }
        return vertices
    }

    /// The zone holding the most bins; a tie goes to the lower one, so a bucket
    /// split evenly across a bound reads as the easier zone rather than flipping
    /// on rounding.
    private static func dominantZone(_ bins: [Int]) -> Int {
        var best = 0
        for zone in 1..<bins.count where bins[zone] > bins[best] { best = zone }
        return best
    }

    /// Rate/effort metrics anchor at zero; level metrics tighten to the data; an
    /// inverting axis reverses and scales to the 98th percentile so a lone
    /// walk/stop spike clips instead of squashing the run. Read from the raw
    /// bins, so resizing or zooming the plot never moves the axis.
    static func domain(values: [Double?], metric: Metric) -> Domain {
        let plots = values.compactMap { $0 }
            .filter(metric.axis.isMoving).map(metric.axis.display).sorted()
        guard let lo = plots.first, let hi = plots.last, hi > 0 else {
            return Domain(lo: 0, hi: 1, reversed: false)
        }
        if metric.axis.isInverting {
            let p98 = plots[Int(0.98 * Double(plots.count - 1))]
            let pad = max((p98 - lo) * 0.15, p98 * 0.02)
            return Domain(lo: max(lo - pad, 0), hi: p98 + pad, reversed: true)
        }
        switch metric.framing {
        case .fromZero:
            return Domain(lo: 0, hi: hi * 1.1, reversed: false)
        case .tight:
            let pad = max((hi - lo) * 0.15, hi * 0.02)
            return Domain(lo: max(lo - pad, 0), hi: hi + pad, reversed: false)
        }
    }

    /// The vertex nearest an elapsed-time offset — what a scrub snaps to.
    static func nearest(to offset: Double, in segments: [Segment]) -> Vertex? {
        segments.lazy.flatMap(\.vertices).min { abs($0.offset - offset) < abs($1.offset - offset) }
    }
}
