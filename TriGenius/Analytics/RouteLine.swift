import Foundation

// MARK: - Route line
//
// One GPS track thinned to what a line on a map needs — the heatmap's unit. A
// year of sessions at 1 Hz is millions of fixes, so each track is reduced once
// and kept in `RouteCache`.

nonisolated struct RouteLine: Codable, Equatable, Sendable {
    let family: SportFamily
    let latitudes: [Double]
    let longitudes: [Double]

    /// The furthest a dropped fix may lie from the drawn line — below what a
    /// 3 pt stroke resolves at any zoom that shows more than a few streets.
    static let toleranceMeters = 10.0
    /// How far from home a session may begin and still count as starting there.
    static let homeRadiusMeters = 50_000.0

    private static let metersPerDegree = 6_371_000 * Double.pi / 180

    /// A decoded stream's recorded fixes, simplified; nil without any. Seconds
    /// without a fix are skipped, so a lost signal draws straight across.
    init?(family: SportFamily, streams: [WorkoutStreams.Metric: [Double?]]) {
        guard let lat = streams[.latitude], let lon = streams[.longitude] else { return nil }
        let fixes = zip(lat, lon).compactMap { lat, lon in
            lat.flatMap { lat in lon.map { (latitude: lat, longitude: $0) } }
        }
        guard !fixes.isEmpty else { return nil }
        let kept = Self.simplified(fixes)
        self.family = family
        latitudes = kept.map(\.latitude)
        longitudes = kept.map(\.longitude)
    }

    /// Douglas–Peucker: the first and last fix, plus every fix further than
    /// `toleranceMeters` from the line through the ones kept around it, on a
    /// plane tangent at the first fix.
    static func simplified(_ fixes: [(latitude: Double, longitude: Double)]) -> [(latitude: Double, longitude: Double)] {
        guard fixes.count > 2 else { return fixes }
        let east = metersPerDegree * cos(fixes[0].latitude * .pi / 180)
        let points = fixes.map { (x: ($0.longitude - fixes[0].longitude) * east,
                                  y: ($0.latitude - fixes[0].latitude) * metersPerDegree) }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var spans = [(0, points.count - 1)]
        while let (a, b) = spans.popLast() {
            let (dx, dy) = (points[b].x - points[a].x, points[b].y - points[a].y)
            let length = dx * dx + dy * dy
            var worst = toleranceMeters, split: Int?
            for i in (a + 1)..<b {
                let (px, py) = (points[i].x - points[a].x, points[i].y - points[a].y)
                // A loop closes on its own start: the span has no direction then.
                let t = length > 0 ? min(max((px * dx + py * dy) / length, 0), 1) : 0
                let distance = hypot(px - t * dx, py - t * dy)
                if distance > worst { (worst, split) = (distance, i) }
            }
            guard let split else { continue }
            keep[split] = true
            spans.append((a, split))
            spans.append((split, b))
        }
        return zip(fixes, keep).compactMap { $1 ? $0 : nil }
    }

    /// The box around the lines starting within `homeRadiusMeters` of home — the
    /// start with the most starts in that radius — so a trip elsewhere does not
    /// stretch it; nil without lines.
    static func homeBounds(_ lines: [RouteLine]) -> (latitudes: ClosedRange<Double>, longitudes: ClosedRange<Double>)? {
        let regions = lines.map { centre in
            let east = metersPerDegree * cos(centre.latitudes[0] * .pi / 180)
            return lines.filter {
                hypot(($0.longitudes[0] - centre.longitudes[0]) * east,
                      ($0.latitudes[0] - centre.latitudes[0]) * metersPerDegree) <= homeRadiusMeters
            }
        }
        guard let home = regions.max(by: { $0.count < $1.count }) else { return nil }
        let latitudes = home.flatMap(\.latitudes), longitudes = home.flatMap(\.longitudes)
        return (latitudes.min()!...latitudes.max()!, longitudes.min()!...longitudes.max()!)
    }
}
