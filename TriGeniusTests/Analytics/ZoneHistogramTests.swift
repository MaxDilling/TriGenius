import Testing
import Foundation
@testable import TriGenius

// Pins the property the recompute path rests on: bucketing the re-expanded
// histogram must land on exactly the seconds bucketing the raw stream did.

@Suite("ZoneHistogram")
struct ZoneHistogramTests {

    /// 100 s at 140 bpm arriving as four separate samples come back as one bin.
    @Test func repeatedValuesAccumulateIntoOneBin() {
        let samples: ZoneSamples = [.heartRate: [(140, 25), (140, 25), (140, 25), (140, 25)]]
        let decoded = ZoneHistogram.decode(ZoneHistogram.encode(samples))
        #expect(decoded?[.heartRate]?.count == 1)
        #expect(decoded?[.heartRate]?.first?.value == 140)
        #expect(decoded?[.heartRate]?.first?.seconds == 100)
    }

    /// The claim the design rests on: same zone seconds, raw stream vs. histogram.
    @Test func bucketingIsUnchangedByTheRoundTrip() {
        let bounds = [130.0, 145.0, 160.0, 175.0]
        let raw: [NormalizedStream.Sample] = [
            (120, 300), (138, 600), (152, 900), (168, 400), (182, 120), (138, 200)
        ]
        let direct = ZoneBucketing.seconds(raw, upperBounds: bounds)
        let roundTripped = ZoneHistogram.decode(ZoneHistogram.encode([.heartRate: raw]))
            .flatMap { ZoneBucketing.seconds($0[.heartRate] ?? [], upperBounds: bounds) }
        #expect(direct == [300, 800, 900, 400, 120])
        #expect(roundTripped == direct)
    }

    /// Pace is the one continuous axis, so it quantizes to cm/s rather than exactly.
    @Test func paceRoundTripsToTheCentimetrePerSecond() {
        let samples: ZoneSamples = [.pace: [(3.456, 60), (3.4561, 60)]]
        let decoded = ZoneHistogram.decode(ZoneHistogram.encode(samples))
        #expect(decoded?[.pace]?.count == 1)
        #expect(decoded?[.pace]?.first?.value == 3.46)
        #expect(decoded?[.pace]?.first?.seconds == 120)
    }

    /// Several metrics survive one blob independently.
    @Test func metricsStaySeparate() {
        let samples: ZoneSamples = [.heartRate: [(150, 60)], .power: [(220, 60), (240, 30)]]
        let decoded = ZoneHistogram.decode(ZoneHistogram.encode(samples))
        #expect(decoded?[.heartRate]?.count == 1)
        #expect(decoded?[.power]?.count == 2)
        #expect(decoded?[.power]?.map(\.seconds).reduce(0, +) == 90)
    }

    /// Absence must stay absence — an empty histogram would read as "no time in any
    /// zone" rather than "never measured".
    @Test func nothingMeasurableEncodesToNothing() {
        #expect(ZoneHistogram.encode([:]).isEmpty)
        #expect(ZoneHistogram.encode([.power: []]).isEmpty)
        #expect(ZoneHistogram.encode([.power: [(220, 0)]]).isEmpty)
        #expect(ZoneHistogram.decode(Data()) == nil)
    }
}
