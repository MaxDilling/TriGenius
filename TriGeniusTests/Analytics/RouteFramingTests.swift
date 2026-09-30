import CoreGraphics
import Testing
@testable import TriGenius

// Pins `Analytics/RouteFraming.swift`. Expected values are hand-computed from
// screen(p) = anchor + (p − centre) × scale.

/// A 100 × 100 route into a 360 × 200 window centred at (200, 200); the camera
/// centre lands at (200, 400) and 1 map point = 1 screen point at 1000 m.
/// Target scale min(3.6, 2) = 2 → distance 1000 × 1 / 2 = 500; the route centre
/// (50, 50) must land on (200, 200): centre = (50 − 0/2, 50 − (200 − 400)/2).
@Test func theRouteLandsCentredInTheWindow() {
    let camera = RouteFraming.camera(showing: CGRect(x: 0, y: 0, width: 100, height: 100),
                                     in: CGRect(x: 20, y: 100, width: 360, height: 200),
                                     anchor: CGPoint(x: 200, y: 400), scale: 1, distance: 1000,
                                     minimumExtent: 1)
    #expect(camera.center == CGPoint(x: 50, y: 150))
    #expect(camera.distance == 500)
}

/// A single fix framed as a 10-point route into a 400 × 800 window centred on
/// the anchor: scale min(40, 80) = 40 from 4 → distance 800 × 4 / 40 = 80, and
/// the camera sits on the fix itself.
@Test func aSingleFixIsFramedAtTheMinimumExtent() {
    let camera = RouteFraming.camera(showing: CGRect(x: 100, y: 100, width: 0, height: 0),
                                     in: CGRect(x: 0, y: 0, width: 400, height: 800),
                                     anchor: CGPoint(x: 200, y: 400), scale: 4, distance: 800,
                                     minimumExtent: 10)
    #expect(camera.center == CGPoint(x: 100, y: 100))
    #expect(camera.distance == 80)
}
