import Foundation

// MARK: - Per-workout zone histogram (value → seconds)
//
// Time in zone is a pure function of how long each *value* was held: `ZoneBucketing`
// only ever sums a sample's seconds into the zone its value falls in, and never looks
// at the order they arrived in. Storing that distribution therefore lets a later
// threshold change re-bucket a workout to exactly the seconds a full re-ingest would
// produce, without keeping the raw stream.
//
// `streamsData` cannot stand in: it is downsampled to ~600 bins, and averaging a
// spiky power stream inside a bin moves time out of z1/z5 into the middle zones —
// a plausible-looking number that isn't the measured one.

nonisolated enum ZoneHistogram {

    /// `{"v":1,"metrics":{metric: {quantized value: seconds}}}` → lzfse. `Data()`
    /// when no metric has samples, so an absent histogram stays absent.
    static func encode(_ samples: ZoneSamples) -> Data {
        var metrics: [String: [String: Double]] = [:]
        for (metric, stream) in samples where !stream.isEmpty {
            var bins: [String: Double] = [:]
            for s in stream where s.seconds > 0 {
                bins["\(Int((s.value * metric.quantum).rounded()))", default: 0] += s.seconds
            }
            if !bins.isEmpty { metrics[metric.rawValue] = bins }
        }
        guard !metrics.isEmpty,
              let data = String(compactJSON: ["v": 1, "metrics": metrics]).data(using: .utf8),
              let compressed = try? (data as NSData).compressed(using: .lzfse)
        else { return Data() }
        return compressed as Data
    }

    /// Back into bucketing input: one sample per distinct value, carrying the total
    /// seconds spent there. Not the original stream — and deliberately not offered as
    /// one — but identical input as far as `ZoneBucketing` is concerned.
    static func decode(_ data: Data) -> ZoneSamples? {
        guard !data.isEmpty,
              let raw = try? (data as NSData).decompressed(using: .lzfse) as Data,
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let metrics = obj["metrics"] as? [String: [String: Any]]
        else { return nil }
        var samples: ZoneSamples = [:]
        for (key, bins) in metrics {
            guard let metric = ZoneMetric(rawValue: key) else { continue }
            let stream = bins.compactMap { bin -> NormalizedStream.Sample? in
                guard let value = Double(bin.key), let seconds = Coerce.double(bin.value) else { return nil }
                return (value: value / metric.quantum, seconds: seconds)
            }
            if !stream.isEmpty { samples[metric] = stream }
        }
        return samples.isEmpty ? nil : samples
    }
}
