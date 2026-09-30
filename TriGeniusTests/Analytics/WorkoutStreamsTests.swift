import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the shared 1 Hz stream codec. Expected values are
// hand-computed per-second averages and deltas. Update alongside
// Analytics/WorkoutStreams.swift.

@Test func downsample_averagesSamplesPerSecond() {
    let bins = WorkoutStreams.downsample([(0, 100), (0.5, 110), (1, 300)], binCount: 2, scale: 1)
    #expect(bins == [105, 300])
}

@Test func downsample_emptyBinIsNil_neverInterpolated() {
    let bins = WorkoutStreams.downsample([(0, 100), (2, 200)], binCount: 3, scale: 1)
    #expect(bins == [100, nil, 200])
}

@Test func downsample_quantizesSpeedToCentimetersPerSecond() {
    let bins = WorkoutStreams.downsample([(0, 3.12)], binCount: 1,
                                         scale: WorkoutStreams.Metric.speed.scale)
    #expect(bins == [312])
}

@Test func downsample_quantizesElevationToDecimeters() {
    let bins = WorkoutStreams.downsample([(0, 12.34)], binCount: 1,
                                         scale: WorkoutStreams.Metric.elevation.scale)
    #expect(bins == [123])
}

@Test func downsample_quantizesLatitudeToOneHundredThousandthDegree() {
    let bins = WorkoutStreams.downsample([(0, 48.137154)], binCount: 1,
                                         scale: WorkoutStreams.Metric.latitude.scale)
    #expect(bins == [4_813_715])
}

@Test func deltaEncoded_gapStaysNil_nextReadingRelativeToLastBeforeGap() {
    #expect(WorkoutStreams.deltaEncoded([100, 102, nil, 101]) == [100, 2, nil, -1])
}

@Test func encode_decode_roundTripsMetricsThroughDeltasAndLZFSE() {
    let data = WorkoutStreams.encode(spanSeconds: 4, metrics: [
        .heartRate: [(0, 92), (1, 94), (3, 95)],
        .speed: [(0, 3.5), (1, 3.5)]
    ])
    #expect(WorkoutStreams.decode(data) ==
        [.heartRate: [92, 94, nil, 95], .speed: [3.5, 3.5, nil, nil]])
}

@Test func encode_decode_roundTripsNegativeCoordinates() {
    let data = WorkoutStreams.encode(spanSeconds: 2, metrics: [.longitude: [(0, -0.12345), (1, -0.12340)]])
    #expect(WorkoutStreams.decode(data)?[.longitude] == [-0.12345, -0.1234])
}

@Test func encode_spanStretchesToLastSample() {
    let data = WorkoutStreams.encode(spanSeconds: 2, metrics: [.power: [(0, 200), (3, 220)]])
    #expect(WorkoutStreams.decode(data)?[.power] == [200, nil, nil, 220])
}

@Test func encode_noSamples_isEmptyData() {
    #expect(WorkoutStreams.encode(spanSeconds: 60, metrics: [.power: []]) == Data())
}

@Test func contains_findsAStoredMetricWithoutDecoding() {
    let data = WorkoutStreams.encode(spanSeconds: 1, metrics: [.latitude: [(0, 48.1)], .heartRate: [(0, 90)]])
    #expect(WorkoutStreams.contains(.latitude, in: data))
    #expect(!WorkoutStreams.contains(.power, in: data))
    #expect(!WorkoutStreams.contains(.latitude, in: Data()))
}

@Test func decode_emptyData_isNil() {
    #expect(WorkoutStreams.decode(Data()) == nil)
}
