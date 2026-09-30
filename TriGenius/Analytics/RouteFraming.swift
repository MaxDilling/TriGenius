import CoreGraphics

// MARK: - Route framing on a full-screen map
//
// The workout page's map always fills the screen; only part of it — the window
// above the page, or the whole screen once the page fades out — is meant to show
// the route. Asking MapKit to fit a rect does not place it there: MapKit fits
// into its own safe area, which is not the window. So the camera is derived from
// how the map projects right now instead, which needs no assumption about
// MapKit's margins. Positions are map points (Mercator, linear on screen).

nonisolated enum RouteFraming {

    /// The camera centre and distance that show `route` scaled to fit and
    /// centred in `window` (screen points). Measured off the current camera: its
    /// centre lands at `anchor` on screen — a point that stays put whatever the
    /// camera — and one map point spans `scale` screen points at its `distance`.
    /// On a flat (unpitched) camera the scale is inversely proportional to the
    /// distance. A route narrower than `minimumExtent` map points on a side — a
    /// single fix, a straight line — is framed as if it were that wide.
    static func camera(showing route: CGRect, in window: CGRect, anchor: CGPoint, scale: Double,
                       distance: Double, minimumExtent: Double) -> (center: CGPoint, distance: Double) {
        let target = min(window.width / max(route.width, minimumExtent),
                         window.height / max(route.height, minimumExtent))
        return (CGPoint(x: route.midX - (window.midX - anchor.x) / target,
                        y: route.midY - (window.midY - anchor.y) / target),
                distance * scale / target)
    }
}
