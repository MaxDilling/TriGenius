import SwiftUI

// MARK: - Body-map geometry
//
// The figure the body view draws, decoded from `body-map-geometry.json` (viewBox
// 120 × 240): a silhouette outline per side and flat regions, each an SVG path
// carrying its muscle group (a group may own several — chest and shoulder are both
// Shoulders), plus tendon sites and the anchors of the forecast pills. The anatomy
// stays editable in the file without touching the renderer.

nonisolated struct TissueBodyGeometry: Decodable, Sendable {
    struct Region: Decodable, Sendable {
        let group: String
        let paths: [SVGPath]
    }

    /// An SVG path in viewBox units, parsed once on load. The file writes absolute
    /// `M`, `C` and `Z` only — the parser reads exactly those.
    struct SVGPath: Decodable, Sendable {
        let path: Path

        init(from decoder: Decoder) throws {
            path = Self.parse(try decoder.singleValueContainer().decode(String.self))
        }

        static func parse(_ d: String) -> Path {
            var path = Path()
            var command: Character = "M"
            var numbers: [CGFloat] = []
            func flush() {
                switch command {
                case "M":
                    guard numbers.count >= 2 else { return }
                    path.move(to: CGPoint(x: numbers[0], y: numbers[1]))
                    numbers.removeFirst(2)
                    command = "L"  // extra pairs after a move are lines, as in SVG
                case "L":
                    guard numbers.count >= 2 else { return }
                    path.addLine(to: CGPoint(x: numbers[0], y: numbers[1]))
                    numbers.removeFirst(2)
                case "C":
                    guard numbers.count >= 6 else { return }
                    path.addCurve(to: CGPoint(x: numbers[4], y: numbers[5]),
                                  control1: CGPoint(x: numbers[0], y: numbers[1]),
                                  control2: CGPoint(x: numbers[2], y: numbers[3]))
                    numbers.removeFirst(6)
                default:
                    return
                }
                flush()
            }
            for token in d.matches(of: /[MCZ]|-?(?:\d+\.?\d*|\.\d+)/).map({ String($0.output) }) {
                if let value = Double(token) {
                    numbers.append(CGFloat(value))
                    flush()
                } else if token == "Z" {
                    path.closeSubpath()
                } else if let letter = token.first {
                    command = letter
                }
            }
            return path
        }
    }

    struct TendonSite: Decodable, Sendable {
        let group: String
        let x: Double
        let y: Double
    }

    let viewBox: [Double]
    /// The silhouette per side ("front" / "back").
    let outline: [String: SVGPath]
    let back: [String: Region]
    let front: [String: Region]
    let tendonSites: [String: [TendonSite]]
    let listOnlyGroups: [String]
    /// Geometry keys that differ from the app's group names ("hams" → "hamstrings").
    let groupKeyMap: [String: String]
    let forecastPillAnchors: [String: [String: [Double]]]

    var size: CGSize { CGSize(width: viewBox[2], height: viewBox[3]) }

    /// The app's group for a geometry key.
    func group(forKey key: String) -> TissueGroup? {
        TissueGroup(rawValue: groupKeyMap[key] ?? key)
    }

    /// The side of the figure a group is drawn on; back is the default, since that is
    /// where most of what a triathlete loads lives.
    func side(for group: TissueGroup) -> TissueBodyMap.Side {
        back.values.contains { self.group(forKey: $0.group) == group } ? .back : .front
    }

    /// Groups whose regions are too thin to tap on the figure; the grid under it is
    /// how they are reached.
    var listOnly: Set<TissueGroup> { Set(listOnlyGroups.compactMap { group(forKey: $0) }) }

    static let shared: TissueBodyGeometry? = {
        guard let url = Bundle.main.url(forResource: "body-map-geometry", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TissueBodyGeometry.self, from: data)
    }()
}
