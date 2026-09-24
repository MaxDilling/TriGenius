import SwiftUI

// MARK: - Body map
//
// A group's state on the figure: each region takes its group's fill (today's muscle
// level on the Tissue Load surfaces), tendon sites sit as diamonds where the tendon
// matters, and a forecast pill names the clear date on the groups that aren't clear yet. A region is tapped anywhere inside its bounds grown
// to 44 pt; the ones too thin even for that (`TissueBodyGeometry.listOnly`) are
// reached through the grid rows under the figure.

struct TissueBodyMap: View {
    enum Side: String, CaseIterable, Identifiable, Sendable {
        case back, front
        var id: String { rawValue }
        var label: String { self == .back ? "Back" : "Front" }
    }

    let side: Side
    /// Region colour per group; groups absent stay clear.
    let fills: [TissueGroup: Color]
    /// Today's state per group, for the tendon diamonds, pills and tap targets.
    var states: [TissueGroup: TissueDayState] = [:]
    /// Clear-forecast label per group, drawn as a pill only where the group isn't clear.
    var forecasts: [TissueGroup: String] = [:]
    var selected: TissueGroup?
    var onSelect: (TissueGroup) -> Void = { _ in }

    private var geometry: TissueBodyGeometry? { TissueBodyGeometry.shared }

    var body: some View {
        if let geometry {
            GeometryReader { proxy in
                let scale = min(proxy.size.width / geometry.size.width,
                                proxy.size.height / geometry.size.height)
                let transform = CGAffineTransform(scaleX: scale, y: scale)
                ZStack(alignment: .topLeading) {
                    geometry.outline[side.rawValue].map { outline in
                        outline.path.applying(transform)
                            .stroke(Theme.Palette.Tissue.clearStroke, lineWidth: 1)
                    }
                    regions(geometry, transform: transform)
                    tendonSites(geometry, scale: scale)
                    pills(geometry, scale: scale)
                    hitZones(geometry, transform: transform)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
            .aspectRatio(geometry.size.width / geometry.size.height, contentMode: .fit)
            .accessibilityHidden(true)
        }
    }

    // MARK: Layers

    private func regions(_ geometry: TissueBodyGeometry, transform: CGAffineTransform) -> some View {
        let regions = (side == .back ? geometry.back : geometry.front).sorted { $0.key < $1.key }
        return ForEach(regions, id: \.key) { _, region in
            let group = geometry.group(forKey: region.group)
            let fill = group.flatMap { fills[$0] } ?? Theme.Palette.Tissue.clear
            ForEach(Array(region.paths.enumerated()), id: \.offset) { _, shape in
                let path = shape.path.applying(transform)
                path.fill(fill)
                    .overlay { if group != nil && group == selected { path.stroke(Color.primary, lineWidth: 1.5) } }
            }
        }
    }

    private func tendonSites(_ geometry: TissueBodyGeometry, scale: CGFloat) -> some View {
        let sites = geometry.tendonSites[side.rawValue] ?? []
        return ForEach(Array(sites.enumerated()), id: \.offset) { _, site in
            if let group = geometry.group(forKey: site.group), let tendon = states[group]?.tendon {
                TendonMark(level: tendon)
                    .offset(x: site.x * scale - TissueMetrics.tendonDiamondBox / 2,
                            y: site.y * scale - TissueMetrics.tendonDiamondBox / 2)
            }
        }
    }

    private func pills(_ geometry: TissueBodyGeometry, scale: CGFloat) -> some View {
        let anchors = geometry.forecastPillAnchors[side.rawValue] ?? [:]
        return ForEach(anchors.sorted { $0.key < $1.key }, id: \.key) { key, point in
            if let group = geometry.group(forKey: key),
               let state = states[group], !state.governingLevel.isClear,
               let label = forecasts[group], point.count == 2 {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, 2)
                    .background(Color.appSecondaryBackground, in: .capsule)
                    .overlay(Capsule().strokeBorder(Theme.Palette.Tissue.clearStroke, lineWidth: 0.5))
                    .fixedSize()
                    .offset(x: point[0] * scale, y: point[1] * scale)
                    .alignmentGuide(.leading) { $0.width / 2 }
                    .alignmentGuide(.top) { $0.height / 2 }
            }
        }
    }

    private struct HitZone {
        let group: TissueGroup
        let rect: CGRect
    }

    /// Each tappable region's bounds, grown to a 44 pt target around their centre.
    /// Smaller regions come last, so where two zones overlap the smaller one wins.
    private func zones(_ geometry: TissueBodyGeometry, transform: CGAffineTransform) -> [HitZone] {
        var zones: [HitZone] = []
        for region in (side == .back ? geometry.back : geometry.front).values {
            guard let group = geometry.group(forKey: region.group), states[group] != nil,
                  !geometry.listOnly.contains(group) else { continue }
            for shape in region.paths {
                let bounds = shape.path.applying(transform).boundingRect
                let width = max(bounds.width, 44), height = max(bounds.height, 44)
                zones.append(HitZone(group: group, rect: CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2,
                                                                width: width, height: height)))
            }
        }
        return zones.sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
    }

    private func hitZones(_ geometry: TissueBodyGeometry, transform: CGAffineTransform) -> some View {
        ForEach(Array(zones(geometry, transform: transform).enumerated()), id: \.offset) { _, zone in
            Color.clear
                .contentShape(Rectangle())
                .frame(width: zone.rect.width, height: zone.rect.height)
                .offset(x: zone.rect.minX, y: zone.rect.minY)
                .onTapGesture { onSelect(zone.group) }
        }
    }
}

