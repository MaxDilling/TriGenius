import Foundation

// MARK: - Per-workout metric streams (downsampled, compressed)
//
// The single stream downsampler + codec. Sources shape each raw metric stream
// into (offset-from-start seconds, value) samples; `encode` resamples every
// metric into the same uniform bin grid (~600 bins per workout) and stores the
// integer-quantized values-only JSON lzfse-compressed in
// `WorkoutRecord.streamsData` (~2–3 KB per workout). Offsets are implicit: bin
// i covers [i·bin_s, (i+1)·bin_s) of elapsed workout time. A bin without
// samples is null (a recording gap/pause), a metric a source can't measure is
// absent — never substituted.

nonisolated enum WorkoutStreams {

    enum Metric: String, CaseIterable, Sendable {
        case heartRate = "heart_rate"   // bpm
        case power                      // W
        case speed                      // m/s, stored ×100 (cm/s)
        case cadence                    // rpm (bike) / spm (run)
        case elevation                  // m, stored ×10 (dm)

        /// Quantization multiplier applied before rounding to Int.
        var scale: Double {
            switch self {
            case .speed: 100
            case .elevation: 10
            default: 1
            }
        }
    }

    /// Uniform bin width (seconds) targeting ~600 bins per workout.
    static func binSeconds(spanSeconds: Double) -> Int {
        max(1, Int((spanSeconds / 600).rounded(.up)))
    }

    /// Scaled integer average of the ~1 Hz samples per bin; an empty bin is nil.
    static func downsample(_ samples: [(offset: Double, value: Double)],
                           binSeconds: Int, binCount: Int, scale: Double) -> [Int?] {
        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)
        for sample in samples {
            let bin = Int(sample.offset) / binSeconds
            guard bin >= 0, bin < binCount else { continue }
            sums[bin] += sample.value
            counts[bin] += 1
        }
        return (0..<binCount).map { bin -> Int? in
            counts[bin] == 0 ? nil : Int((sums[bin] / Double(counts[bin]) * scale).rounded())
        }
    }

    /// `{"v":1,"bin_s":…,"metrics":{…}}` → lzfse. `Data()` when no metric has
    /// samples. The span stretches to the last sample so timestamp-gapped
    /// (paused) recordings keep every sample addressable.
    static func encode(spanSeconds: Double,
                       metrics: [Metric: [(offset: Double, value: Double)]]) -> Data {
        let present = metrics.filter { !$0.value.isEmpty }
        guard !present.isEmpty else { return Data() }
        let lastOffset = present.values.lazy.flatMap { $0 }.map(\.offset).max() ?? 0
        let span = max(spanSeconds, lastOffset + 1)
        let bin = binSeconds(spanSeconds: span)
        let count = Int((span / Double(bin)).rounded(.up))
        var encoded: [String: Any] = [:]
        for (metric, samples) in present {
            let values = downsample(samples, binSeconds: bin, binCount: count, scale: metric.scale)
            encoded[metric.rawValue] = values.map { v -> Any in if let v { v } else { NSNull() } }
        }
        let json = String(compactJSON: ["v": 1, "bin_s": bin, "metrics": encoded])
        guard let data = json.data(using: .utf8),
              let compressed = try? (data as NSData).compressed(using: .lzfse)
        else { return Data() }
        return compressed as Data
    }

    struct Decoded: Sendable {
        let binSeconds: Int
        let metrics: [Metric: [Double?]]   // natural units (÷scale)
    }

    static func decode(_ data: Data) -> Decoded? {
        guard !data.isEmpty,
              let raw = try? (data as NSData).decompressed(using: .lzfse) as Data,
              let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let bin = obj["bin_s"] as? Int,
              let metricsDict = obj["metrics"] as? [String: [Any]]
        else { return nil }
        var metrics: [Metric: [Double?]] = [:]
        for (key, values) in metricsDict {
            guard let metric = Metric(rawValue: key) else { continue }
            metrics[metric] = values.map { ($0 as? NSNumber).map { $0.doubleValue / metric.scale } }
        }
        return Decoded(binSeconds: bin, metrics: metrics)
    }
}
