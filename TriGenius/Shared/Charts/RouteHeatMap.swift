import SwiftUI
import MapKit

// MARK: - Route heatmap
//
// Every `RouteLine` of a range on one map, each a translucent stroke in its
// sport's color: strokes add up, so a road travelled in many sessions reads
// stronger. The map opens on the home region (`RouteLine.homeBounds`) and
// returns to it whenever the lines change — hiding a sport leaves the camera alone.

struct RouteHeatMap: View {
    let lines: [RouteLine]
    var interactive = false
    var hidden: Set<SportFamily> = []

    @AppStorage(routeSatelliteKey) private var satellite = false
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera, interactionModes: interactive ? [.pan, .zoom] : []) {
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                if !hidden.contains(line.family) {
                    MapPolyline(coordinates: zip(line.latitudes, line.longitudes).map(CLLocationCoordinate2D.init))
                        .stroke(line.family.color.opacity(0.25),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .mapStyle(satellite ? .hybrid(pointsOfInterest: .excludingAll) : .standard(pointsOfInterest: .excludingAll))
        .allowsHitTesting(interactive)
        .onChange(of: lines, initial: true) {
            guard let (lat, lon) = RouteLine.homeBounds(lines) else { return }
            // 15 % room a side.
            camera = .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: (lat.lowerBound + lat.upperBound) / 2,
                                               longitude: (lon.lowerBound + lon.upperBound) / 2),
                span: MKCoordinateSpan(latitudeDelta: (lat.upperBound - lat.lowerBound) * 1.3,
                                       longitudeDelta: (lon.upperBound - lon.lowerBound) * 1.3)))
        }
    }
}
