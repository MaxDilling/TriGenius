import SwiftUI
import MapKit

// MARK: - Workout route map
//
// The GPS track stored in `streamsData` on Apple Maps, behind the workout page's
// title. The map is still until tapped — live inside the page's scroll view, it
// would take the scroll gestures — and marks the fix under a scrubbed chart.

struct RouteTrack: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    /// Elapsed seconds of each fix on the timeline the charts scrub — on a
    /// multisport race the leg's own offset included.
    let offsets: [Double]
    let color: Color

    /// A decoded stream's recorded fixes; nil without any. Seconds without a fix
    /// are skipped, so a lost signal draws straight across.
    init?(id: Int, streams: [WorkoutStreams.Metric: [Double?]], startingAt start: Double, color: Color) {
        guard let lat = streams[.latitude], let lon = streams[.longitude] else { return nil }
        var coordinates: [CLLocationCoordinate2D] = []
        var offsets: [Double] = []
        for (i, (lat, lon)) in zip(lat, lon).enumerated() {
            guard let lat, let lon else { continue }
            coordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            offsets.append(start + (Double(i) + 0.5) * Double(WorkoutStreams.binSeconds))
        }
        guard !coordinates.isEmpty else { return nil }
        self.id = id
        self.coordinates = coordinates
        self.offsets = offsets
        self.color = color
    }

    /// The fix nearest `offset` across `tracks` — none when even that one is
    /// further than `StreamPlot.holdSeconds` away: a pause, or no signal.
    static func position(at offset: Double, in tracks: [RouteTrack]) -> (CLLocationCoordinate2D, Color)? {
        var best: (gap: Double, coordinate: CLLocationCoordinate2D, color: Color)?
        for track in tracks {
            var lo = 0, hi = track.offsets.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if track.offsets[mid] < offset { lo = mid + 1 } else { hi = mid }
            }
            for i in [lo - 1, lo] where track.offsets.indices.contains(i) {
                let gap = abs(track.offsets[i] - offset)
                if gap < best?.gap ?? .infinity { best = (gap, track.coordinates[i], track.color) }
            }
        }
        guard let best, best.gap <= StreamPlot.holdSeconds else { return nil }
        return (best.coordinate, best.color)
    }

    /// What the map frames: the track `focus` names, else every track — a leg
    /// without a fix of its own (a transition) leaves the whole route in view.
    static func framed(_ tracks: [RouteTrack], focus: Int?) -> [CLLocationCoordinate2D] {
        tracks.first { $0.id == focus }?.coordinates ?? tracks.flatMap(\.coordinates)
    }
}

/// The moment a chart is scrubbed to, on the route's timeline. Only the map's
/// marker reads it, so a hover never re-renders the page around the map.
@Observable final class RouteCursor {
    var offset: Double?
}

extension EnvironmentValues {
    @Entry var routeCursor: RouteCursor? = nil
    /// Added to a chart's own elapsed time to reach the route's — a race leg's
    /// start, on that leg's charts.
    @Entry var routeCursorBase: Double = 0
}

/// The route map as the workout page's header card (the wide layout): the title
/// over its lower edge, a tap opens the map in a sheet.
struct RouteHeader<Caption: View>: View {
    /// One track per leg on a multisport race, each in its leg's color; nil
    /// while the streams are still decoding — the header already holds its
    /// place, so the page does not jump when the map arrives.
    let tracks: [RouteTrack]?
    /// The leg the map zooms to and sets off from the others; nil for the whole route.
    var focus: Int?
    @ViewBuilder let caption: Caption

    @State private var showDetail = false
    @State private var camera: MapCameraPosition = .automatic
    @State private var captionHeight = routeCaptionHeight

    var body: some View {
        ZStack {
            Color.appSecondaryBackground
            if let tracks {
                MapReader { proxy in
                    RouteMap(tracks: tracks, focus: focus, interactive: false, camera: $camera)
                        .safeAreaPadding(.bottom, captionHeight)
                        .overlay { CursorMarker(proxy: proxy, tracks: tracks).ignoresSafeArea() }
                }
                .onChange(of: focus, initial: true) {
                    withAnimation(.smooth(duration: 0.7)) {
                        camera = tracks.first { $0.id == focus }.flatMap { MKMapRect(bounding: $0.coordinates) }
                            .map { .rect($0.withMargin) } ?? .automatic
                    }
                }
            }
        }
        .frame(height: routeWindowHeight - routeCaptionHeight + captionHeight)
        .overlay(alignment: .bottom) {
            caption.routeCaption(fadingInto: .appSecondaryBackground, over: captionHeight + 80)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { captionHeight = $0 }
        }
        .clipShape(.rect(cornerRadius: Theme.Radius.l, style: .continuous))
        .onTapGesture { if tracks != nil { showDetail = true } }
        .overlay(alignment: .topTrailing) {
            if tracks != nil {
                RouteMapStyleButton()
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(Theme.Spacing.m)
            }
        }
        .sheet(isPresented: $showDetail) {
            RouteMapDetail(tracks: tracks ?? [], focus: focus)
        }
    }
}

/// The phone layout, as Apple Fitness: the map fills the screen behind the page,
/// which scrolls over it and leaves a window at the top. A tap hides the page
/// and moves only the camera, from the window to the whole screen — the map
/// never changes size or safe area, because MapKit refits on every frame of that.
struct RouteMapPage<Caption: View, Content: View>: View {
    let tracks: [RouteTrack]?
    /// The leg the map zooms to and sets off from the others; nil for the whole route.
    var focus: Int?
    @ViewBuilder let caption: Caption
    @ViewBuilder let content: Content

    @State private var expanded = false
    @State private var camera: MapCameraPosition = .automatic
    /// The route framed in the window and on the whole screen — nil until
    /// measured off the map, which stays hidden until then.
    @State private var framings: (window: MapCamera, screen: MapCamera)?
    @State private var restingCamera: MapCamera?
    @State private var screen: CGSize = .zero
    @State private var insets = EdgeInsets()
    @State private var depth = ScrollDepth()
    @State private var pastHeader = false

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            ScrollView {
                VStack(spacing: 0) {
                    caption
                        .padding([.horizontal, .top], Theme.Spacing.l)
                        .frame(maxWidth: .infinity, minHeight: insets.top + routeWindowHeight,
                               alignment: .bottomLeading)
                        .contentShape(Rectangle())
                        .onTapGesture { if framings != nil { resize(expanded: true) } }
                    content
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, offset in
                depth.value = min(max(offset / routeWindowHeight, 0), 1)
                if (offset >= routeWindowHeight) != pastHeader { pastHeader.toggle() }
            }
            .ignoresSafeArea(edges: .top)
            .scrollEdgeEffectHidden(!pastHeader, for: .top)
            .opacity(expanded ? 0 : 1)
            .offset(y: expanded ? Theme.Spacing.xl : 0)
            // Gone in one frame, back with the camera: rising as it fades in.
            .animation(expanded ? nil : .smooth(duration: 0.5), value: expanded)
            .allowsHitTesting(!expanded)
        }
        .navigationBarBackButtonHidden(expanded)
        .toolbar {
            if expanded {
                ToolbarItem(placement: .navigation) {
                    Button { resize(expanded: false) } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                }
            }
        }
        #if os(iOS)
        .toolbar(removing: .title)
        #endif
    }

    /// The map, the page background rising over its lower part, and the
    /// scroll-driven blur.
    private var backdrop: some View {
        ZStack(alignment: .top) {
            Color.appBackground
            if let tracks {
                MapReader { proxy in
                    RouteMap(tracks: tracks, focus: focus, interactive: expanded, camera: $camera)
                        .overlay { CursorMarker(proxy: proxy, tracks: tracks).ignoresSafeArea() }
                        .onChange(of: focus) {
                            withAnimation(.smooth(duration: 0.7)) { frame(with: proxy) }
                        }
                        .onMapCameraChange(frequency: .onEnd) { context in
                            restingCamera = context.camera
                            if framings == nil { frame(with: proxy) }
                        }
                        .onChange(of: [screen.width, screen.height, insets.top, insets.bottom,
                                       insets.leading, insets.trailing]) {
                            // Not measured here: the map has not taken the new geometry
                            // yet. The refit ends in a camera change, which measures.
                            framings = nil
                            camera = .automatic
                        }
                }
                .opacity(framings == nil ? 0 : 1)
            }
            // The fade is a background so its fixed heights never size the backdrop:
            // taller than a landscape screen, they feed back through `insets` forever.
            ScrollDim(depth: depth)
                .background(alignment: .top) {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: max(insets.top + routeWindowHeight - routeFadeHeight + routeFadeOverhang, 0))
                        LinearGradient(stops: routeFadeStops(.appBackground), startPoint: .top, endPoint: .bottom)
                            .frame(height: routeFadeHeight)
                        Color.appBackground
                    }
                }
                .opacity(expanded ? 0 : 1)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .onGeometryChange(for: CGSize.self) { $0.size } action: { screen = $0 }
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets = $0 }
    }

    private func resize(expanded: Bool) {
        guard let framings else { return }
        withAnimation(.smooth(duration: 0.7)) {
            self.expanded = expanded
            camera = .camera(expanded ? framings.screen : framings.window)
        }
    }

    /// Measures how the map projects under the resting camera — where its centre
    /// lands, and how many screen points one map point spans — and derives the
    /// two framings from that (`RouteFraming.camera`), both clear of everything
    /// the map runs under: the bars, and on iPad the sidebar.
    private func frame(with proxy: MapProxy) {
        guard let tracks, let current = restingCamera, screen.width > 0,
              let route = MKMapRect(bounding: RouteTrack.framed(tracks, focus: focus)),
              let anchor = proxy.convert(current.centerCoordinate, to: .local) else { return }
        let centre = MKMapPoint(current.centerCoordinate)
        guard let probe = proxy.convert(MKMapPoint(x: centre.x + 1000, y: centre.y).coordinate, to: .local),
              probe.x > anchor.x else { return }
        let margin = Theme.Spacing.xl
        let top = insets.top + margin
        func framing(bottom: CGFloat) -> MapCamera {
            let placed = RouteFraming.camera(
                showing: CGRect(x: route.origin.x, y: route.origin.y, width: route.size.width, height: route.size.height),
                in: CGRect(x: insets.leading + margin, y: top,
                           width: screen.width - insets.leading - insets.trailing - 2 * margin,
                           height: bottom - top),
                anchor: anchor, scale: (probe.x - anchor.x) / 1000, distance: current.distance,
                minimumExtent: 200 * MKMapPointsPerMeterAtLatitude(current.centerCoordinate.latitude))
            return MapCamera(centerCoordinate: MKMapPoint(x: placed.center.x, y: placed.center.y).coordinate,
                             distance: placed.distance)
        }
        let framed = (window: framing(bottom: insets.top + routeWindowHeight - routeCaptionHeight - margin),
                      screen: framing(bottom: screen.height - insets.bottom - margin))
        framings = framed
        camera = .camera(expanded ? framed.screen : framed.window)
    }
}

/// How far the page has scrolled over its header, 0…1 — read only by the dim,
/// so scrolling re-renders the blur and not the page.
@Observable private final class ScrollDepth {
    var value: Double = 0
}

private struct ScrollDim: View {
    let depth: ScrollDepth

    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial).opacity(depth.value)
            Color.appBackground.opacity(depth.value * depth.value)
        }
    }
}

/// An eased fade into `color` — long and soft, so the map dissolves into the
/// page rather than ending at an edge.
private func routeFadeStops(_ color: Color) -> [Gradient.Stop] {
    [.init(color: color.opacity(0), location: 0), .init(color: color.opacity(0.3), location: 0.2),
     .init(color: color.opacity(0.55), location: 0.7), .init(color: color, location: 1)]
}

private let routeFadeHeight: CGFloat = 320
/// How far below the window the page's background turns solid — under the
/// title the map still shows through.
private let routeFadeOverhang: CGFloat = 80

/// The visible map above the page, and the part of it the title covers.
private let routeWindowHeight: CGFloat = 260
private let routeCaptionHeight: CGFloat = 72

private extension MKMapRect {
    init?(bounding coordinates: [CLLocationCoordinate2D]) {
        let points = coordinates.map(MKMapPoint.init)
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        self.init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Room around a framed leg: 15 % a side, and at least 100 m so a
    /// transition's few metres do not fill the map.
    var withMargin: MKMapRect {
        let floor = 100 * MKMapPointsPerMeterAtLatitude(origin.coordinate.latitude)
        return insetBy(dx: -0.15 * width - floor, dy: -0.15 * height - floor)
    }
}

private extension View {
    /// The title block over the map's lower edge, on a fade into `fade` that
    /// starts `height` above the block's foot.
    func routeCaption(fadingInto fade: Color, over height: CGFloat) -> some View {
        padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottom) {
                LinearGradient(stops: routeFadeStops(fade), startPoint: .top, endPoint: .bottom)
                    .frame(height: height)
                    .allowsHitTesting(false)
            }
    }
}

private struct CursorMarker: View {
    let proxy: MapProxy
    let tracks: [RouteTrack]
    @Environment(\.routeCursor) private var cursor

    var body: some View {
        if let offset = cursor?.offset, let fix = RouteTrack.position(at: offset, in: tracks),
           let point = proxy.convert(fix.0, to: .local) {
            RouteDot(color: fix.1, size: 14).position(point)
        }
    }
}

private struct RouteDot: View {
    let color: Color
    var size: CGFloat = 12

    var body: some View {
        Circle().fill(color)
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .frame(width: size, height: size)
    }
}

private struct RouteMapDetail: View {
    let tracks: [RouteTrack]
    let focus: Int?
    @Environment(\.dismiss) private var dismiss
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        RouteMap(tracks: tracks, focus: focus, interactive: true, camera: $camera)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                HStack {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    RouteMapStyleButton()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .padding(Theme.Spacing.l)
            }
            .windowFillingSheet()
    }
}

private struct RouteMap: View {
    let tracks: [RouteTrack]
    let focus: Int?
    let interactive: Bool
    @Binding var camera: MapCameraPosition

    @AppStorage(routeSatelliteKey) private var satellite = false

    var body: some View {
        Map(position: $camera, interactionModes: interactive ? [.pan, .zoom] : []) {
            ForEach(tracks) { track in
                MapPolyline(coordinates: track.coordinates)
                    .stroke(track.color.opacity(focus == nil || focus == track.id ? 1 : 0.3),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
            if let start = tracks.first?.coordinates.first {
                Annotation("Start", coordinate: start) { RouteDot(color: Theme.Palette.success) }
                    .annotationTitles(.hidden)
            }
            if let finish = tracks.last?.coordinates.last {
                Annotation("Finish", coordinate: finish) { RouteDot(color: Theme.Palette.danger) }
                    .annotationTitles(.hidden)
            }
        }
        .mapStyle(satellite ? .hybrid(pointsOfInterest: .excludingAll) : .standard(pointsOfInterest: .excludingAll))
        .allowsHitTesting(interactive)
    }
}

/// Satellite imagery with roads over the standard map, for every route map at
/// once and remembered across launches.
let routeSatelliteKey = "route_map_satellite"

struct RouteMapStyleButton: View {
    @AppStorage(routeSatelliteKey) private var satellite = false

    var body: some View {
        Button("Map style", systemImage: "map") { satellite.toggle() }
            .symbolVariant(satellite ? .fill : .none)
    }
}

/// A throwaway map under the app's opaque tabs, rendered once at launch: the
/// first map of a session initializes MapKit on the main thread for seconds,
/// which otherwise freezes the push into the first workout. Rendering is what
/// warms it, so it must not be hidden. `mapWarmUp` signposts the cost.
struct MapWarmUp: View {
    private enum Phase { case waiting, warming(Perf.Span), done }
    @State private var phase = Phase.waiting

    var body: some View {
        // A real view underneath, so the task runs before any map exists.
        Color.clear
            .frame(width: 64, height: 64)
            .overlay {
                if case .warming(let span) = phase {
                    Map(interactionModes: [])
                        .onMapCameraChange {
                            Perf.end(span)
                            phase = .done
                        }
                }
            }
            .allowsHitTesting(false)
            .task {
                if case .waiting = phase { phase = .warming(Perf.begin("mapWarmUp")) }
            }
    }
}
