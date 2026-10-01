import Foundation

/// The y axis of a metric's detail chart: ticks a 1-2-5 step apart that is never finer than
/// what the labels show, so no two labels can read the same — a flat VO2max between 55.6 and
/// 56.2 drew four gridlines all labelled "56".
nonisolated enum MetricAxis {

    struct Axis: Equatable {
        let domain: ClosedRange<Double>
        let ticks: [Double]
    }

    /// `values` in the unit the labels show, `resolution` the smallest difference they show
    /// (1 for whole numbers, 0.1 for one decimal, 1 s for a pace). Aims at `count` ticks and
    /// never draws fewer than three; the domain runs `pad` of the tick span past the outer
    /// ticks, so a line on a tick does not ride the frame. A series spanning less than
    /// `minSpan` is framed as if it spanned that much, centred — or a change inside the
    /// marker's own noise fills the chart.
    static func axis(_ values: [Double], resolution: Double, minSpan: Double = 0, count: Int = 4,
                     pad: Double = 0.1) -> Axis? {
        guard var lo = values.min(), var hi = values.max(), resolution > 0 else { return nil }
        if hi - lo < minSpan {
            let mid = (lo + hi) / 2
            (lo, hi) = (mid - minSpan / 2, mid + minSpan / 2)
        }
        let step = niceStep(max((hi - lo) / Double(count - 1), resolution), resolution: resolution)
        var first = (lo / step).rounded(.down) * step
        var last = (hi / step).rounded(.up) * step
        if last - first < 2 * step { first -= step }
        if last - first < 2 * step { last += step }
        let steps = Int(((last - first) / step).rounded())
        let margin = (last - first) * pad
        return Axis(domain: (first - margin)...(last + margin),
                    ticks: (0...steps).map { first + Double($0) * step })
    }

    /// The smallest 1-2-5 step at or above `raw` that is a whole multiple of `resolution`.
    static func niceStep(_ raw: Double, resolution: Double) -> Double {
        var magnitude = pow(10, log10(raw).rounded(.down))
        while true {
            for m in [1.0, 2, 5] {
                let step = m * magnitude
                let multiple = step / resolution
                if step >= raw * (1 - 1e-9), abs(multiple - multiple.rounded()) < 1e-9 { return step }
            }
            magnitude *= 10
        }
    }
}
