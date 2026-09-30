import Foundation
import Testing
@testable import TriGenius

// Pins `MetricAxis`: ticks a 1-2-5 step apart, never finer than the labels show, at least
// three. Expected values hand-computed.
struct MetricAxisTests {

    private func close(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    @Test func aFlatSeriesGetsThreeDistinctWholeNumberTicks() throws {
        // 55.6 - 56.2 drew four gridlines all labelled "56": the step is held at 1, and the
        // series is framed by a tick either side.
        let axis = try #require(MetricAxis.axis([55.6, 56.2], resolution: 1))
        #expect(close(axis.ticks, [55, 56, 57]))
        #expect(abs(axis.domain.lowerBound - 54.8) < 1e-9 && abs(axis.domain.upperBound - 57.2) < 1e-9)
    }

    @Test func aWideSeriesTakesTheNiceStepAboveASpanOverThree() throws {
        // (56 - 50) / 3 = 2 -> step 2, ticks 50 ... 56; padded by 0.1 x 6.
        let axis = try #require(MetricAxis.axis([50, 53.1, 56], resolution: 1))
        #expect(close(axis.ticks, [50, 52, 54, 56]))
        #expect(abs(axis.domain.lowerBound - 49.4) < 1e-9 && abs(axis.domain.upperBound - 56.6) < 1e-9)
    }

    @Test func oneDecimalLabelsStepByATenth() throws {
        let axis = try #require(MetricAxis.axis([70.3, 70.4], resolution: 0.1))
        #expect(close(axis.ticks, [70.2, 70.3, 70.4]))
    }

    @Test func theStepIsAOneTwoFiveMultipleOfTheResolution() {
        #expect(MetricAxis.niceStep(2.5, resolution: 1) == 5)
        #expect(MetricAxis.niceStep(12, resolution: 1) == 20)
        #expect(abs(MetricAxis.niceStep(0.3, resolution: 0.1) - 0.5) < 1e-12)
    }

    @Test func noValuesGiveNoAxis() {
        #expect(MetricAxis.axis([], resolution: 1) == nil)
    }
}
