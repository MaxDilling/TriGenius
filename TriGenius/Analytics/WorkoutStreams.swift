import Foundation

// MARK: - Per-workout metric streams (1 Hz, delta-encoded, compressed)
//
// The single stream codec. Sources shape each raw metric stream into
// (offset-from-start seconds, value) samples; `encode` resamples every metric
// onto one 1 s grid, integer-quantizes it, stores each series as deltas to the
// previous reading and lzfse-compresses the values-only JSON into
// `WorkoutRecord.streamsData` (~12 KB per hour, ~15 KB with GPS). Offsets are
// implicit: bin i covers [i, i+1) s of elapsed workout time. A bin without
// samples is null (no reading that second — see `StreamPlot.holdSeconds`), a
// metric a source can't measure is absent — never substituted.

nonisolated enum WorkoutStreams {

    enum Metric: String, CaseIterable, Sendable {
        case heartRate = "heart_rate"   // bpm
        case power                      // W
        case speed                      // m/s, stored ×100 (cm/s)
        case cadence                    // rpm (bike) / spm (run)
        case elevation                  // m, stored ×10 (dm)
        case latitude, longitude        // degrees, stored ×1e5 (~1 m)

        /// Quantization multiplier applied before rounding to Int.
        var scale: Double {
            switch self {
            case .speed: 100
            case .elevation: 10
            case .latitude, .longitude: 100_000
            default: 1
            }
        }
    }

    /// The stored resolution: one bin per second of elapsed time.
    static let binSeconds = 1

    /// Scaled integer average of the samples per 1 s bin; an empty bin is nil.
    static func downsample(_ samples: [(offset: Double, value: Double)],
                           binCount: Int, scale: Double) -> [Int?] {
        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)
        for sample in samples {
            let bin = Int(sample.offset)
            guard bin >= 0, bin < binCount else { continue }
            sums[bin] += sample.value
            counts[bin] += 1
        }
        return (0..<binCount).map { bin -> Int? in
            counts[bin] == 0 ? nil : Int((sums[bin] / Double(counts[bin]) * scale).rounded())
        }
    }

    /// Each reading as its difference to the previous one — mostly 0 or ±1, which
    /// is what makes a 1 Hz stream compress. A gap stays nil; the reading after it
    /// is relative to the one before it.
    static func deltaEncoded(_ values: [Int?]) -> [Int?] {
        var previous = 0
        return values.map { value in
            guard let value else { return nil }
            defer { previous = value }
            return value - previous
        }
    }

    /// `{"v":2,"metrics":{…}}` → lzfse. `Data()` when no metric has samples. The
    /// span stretches to the last sample so timestamp-gapped (paused) recordings
    /// keep every sample addressable.
    static func encode(spanSeconds: Double,
                       metrics: [Metric: [(offset: Double, value: Double)]]) -> Data {
        let present = metrics.filter { !$0.value.isEmpty }
        guard !present.isEmpty else { return Data() }
        let lastOffset = present.values.lazy.flatMap { $0 }.map(\.offset).max() ?? 0
        let count = Int(max(spanSeconds, lastOffset + 1).rounded(.up))
        var encoded: [String: Any] = [:]
        for (metric, samples) in present {
            let deltas = deltaEncoded(downsample(samples, binCount: count, scale: metric.scale))
            encoded[metric.rawValue] = deltas.map { v -> Any in if let v { v } else { NSNull() } }
        }
        let json = String(compactJSON: ["v": 2, "metrics": encoded])
        guard let data = json.data(using: .utf8),
              let compressed = try? (data as NSData).compressed(using: .lzfse)
        else { return Data() }
        return compressed as Data
    }

    /// Whether a blob stores `metric` — decompression and a key lookup, no parse,
    /// so a view can settle its layout before the full decode lands.
    static func contains(_ metric: Metric, in data: Data) -> Bool {
        guard !data.isEmpty, let raw = try? (data as NSData).decompressed(using: .lzfse) as Data
        else { return false }
        return raw.range(of: Data("\"\(metric.rawValue)\":".utf8)) != nil
    }

    /// Every stored metric per 1 s bin, in natural units (÷scale).
    static func decode(_ data: Data) -> [Metric: [Double?]]? {
        guard !data.isEmpty,
              let raw = try? (data as NSData).decompressed(using: .lzfse) as Data,
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              obj["v"] as? Int == 2,
              let metricsDict = obj["metrics"] as? [String: [Any]]
        else { return nil }
        var metrics: [Metric: [Double?]] = [:]
        for (key, deltas) in metricsDict {
            guard let metric = Metric(rawValue: key) else { continue }
            var running = 0
            metrics[metric] = deltas.map { delta -> Double? in
                guard let delta = delta as? NSNumber else { return nil }
                running += delta.intValue
                return Double(running) / metric.scale
            }
        }
        return metrics
    }
}
