import Foundation
import Testing
@testable import TriGenius

// Golden-master pins for the shared stream downsampler + codec. Expected values
// are hand-computed bin averages. Update alongside Analytics/WorkoutStreams.swift.

@Test func binSeconds_underTargetBins_isOneSecond() {
    #expect(WorkoutStreams.binSeconds(spanSeconds: 599) == 1)
}

@Test func binSeconds_oneHour_isSixSeconds() {
    #expect(WorkoutStreams.binSeconds(spanSeconds: 3600) == 6)
}

@Test func downsample_averagesSamplesPerBin() {
    let bins = WorkoutStreams.downsample([(0, 100), (1, 110), (2, 300)],
                                         binSeconds: 2, binCount: 2, scale: 1)
    #expect(bins == [105, 300])
}

@Test func downsample_emptyBinIsNil_neverInterpolated() {
    let bins = WorkoutStreams.downsample([(0, 100), (4, 200)],
                                         binSeconds: 2, binCount: 3, scale: 1)
    #expect(bins == [100, nil, 200])
}

@Test func downsample_quantizesSpeedToCentimetersPerSecond() {
    let bins = WorkoutStreams.downsample([(0, 3.12)], binSeconds: 1, binCount: 1,
                                         scale: WorkoutStreams.Metric.speed.scale)
    #expect(bins == [312])
}

@Test func downsample_quantizesElevationToDecimeters() {
    let bins = WorkoutStreams.downsample([(0, 12.34)], binSeconds: 1, binCount: 1,
                                         scale: WorkoutStreams.Metric.elevation.scale)
    #expect(bins == [123])
}

@Test func encode_decode_roundTripsBinWidth() {
    let data = WorkoutStreams.encode(spanSeconds: 4, metrics: [.heartRate: [(0, 92)]])
    #expect(WorkoutStreams.decode(data)?.binSeconds == 1)
}

@Test func encode_decode_roundTripsMetricsThroughLZFSE() {
    let data = WorkoutStreams.encode(spanSeconds: 4, metrics: [
        .heartRate: [(0, 92), (1, 94), (3, 95)],
        .speed: [(0, 3.5), (1, 3.5)]
    ])
    #expect(WorkoutStreams.decode(data)?.metrics ==
        [.heartRate: [92, 94, nil, 95], .speed: [3.5, 3.5, nil, nil]])
}

@Test func encode_spanStretchesToLastSample() {
    let data = WorkoutStreams.encode(spanSeconds: 2, metrics: [.power: [(0, 200), (3, 220)]])
    #expect(WorkoutStreams.decode(data)?.metrics[.power] == [200, nil, nil, 220])
}

@Test func encode_noSamples_isEmptyData() {
    #expect(WorkoutStreams.encode(spanSeconds: 60, metrics: [.power: []]) == Data())
}

@Test func decode_emptyData_isNil() {
    #expect(WorkoutStreams.decode(Data()) == nil)
}
