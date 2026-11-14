import simd
import SwiftUI

// MARK: - Exercise animation
//
// One exercise's rep, looped at its tempo. `ExercisePose` places the skeleton; this
// only draws it, Garmin style: a grey androgynous figure in shirt and shorts, far-side
// limbs a shade darker, props as plain shapes, and the worked muscles in the Tissue Load
// reds (primary heavy, secondary moderate).
//
// The body is one silhouette, not jointed parts: everything in a depth layer shares one
// outline (`outline`), and clothing is painted over the finished body. Muscles are
// ellipses cut to their body part — never rectangles: a straight edge across the body
// reads as clothing. The barbell has no plates: at this camera a plate hides the lifter.

struct ExerciseAnimation: View {
    let pose: ExercisePose
    let muscles: ExerciseMuscles
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let progress = reduceMotion ? 1 : pose.progress(at: context.date.timeIntervalSinceReferenceDate)
            Canvas { gc, size in
                FigurePainter.draw(pose: pose, skeleton: pose.skeleton(at: progress), muscles: muscles, in: gc, size: size)
            }
        }
        .accessibilityHidden(true)
    }
}

extension ExerciseAnimation {
    /// The animation for a library exercise, or nil when it has no pose yet.
    init?(exercise: Exercise) {
        guard let pose = ExercisePoses.all[exercise.id] else { return nil }
        self.init(pose: pose, muscles: ExerciseMuscles(exercise))
    }
}

private struct FigurePainter {
    typealias Point = SIMD2<Double>
    private typealias F = Theme.Palette.Figure
    private typealias Body = ExercisePose.Body

    let gc: GraphicsContext
    let pose: ExercisePose
    let sk: ExercisePose.Skeleton
    let muscles: ExerciseMuscles
    /// Outline width in metres.
    let ow: Double

    /// Where a body part's own (front, along) lands on the canvas.
    private typealias Map = (Point) -> Point
    /// A muscle as an ellipse in its body part's axes.
    private typealias Belly = (muscles: [GarminMuscle], center: Point, radius: Point)

    /// A straight body part: `front` across it, `up` along it.
    private struct Frame {
        var origin, front, up: Point
        func callAsFunction(_ q: Point) -> Point { origin + front * q.x + up * q.y }
    }

    private struct Limb {
        var root, end: Frame
        var upper, lower, joint: Path
        /// The hand or the shoe.
        var tip: Path
        var paths: [Path] { [upper, lower, joint, tip] }
    }

    /// Outline widths as multiples of `ow`: the figure's silhouette, and a part crossing it.
    private static let heavy = 1.5, thin = 0.7

    /// (front, up) in metres from the pelvis, along the spine.
    private static let torsoSide: [Point] = [[-0.12, -0.08], [0.09, -0.09], [0.105, 0.1], [0.1, 0.25], [0.125, 0.4], [0.095, 0.5],
                                             [0, 0.56], [-0.095, 0.52], [-0.115, 0.38], [-0.09, 0.2], [-0.14, 0.05]]
    private static let torsoFront: [Point] = [[0.185, -0.1], [0.2, 0.03], [0.155, 0.2], [0.16, 0.34], [0.185, 0.45], [0.19, 0.53],
                                              [0.1, 0.56], [0.045, 0.545], [-0.045, 0.545], [-0.1, 0.56], [-0.19, 0.53],
                                              [-0.185, 0.45], [-0.16, 0.34], [-0.155, 0.2], [-0.2, 0.03], [-0.185, -0.1], [0, -0.13]]
    /// Limb outlines: (front in metres, along as a fraction of the segment), root to end.
    private static let thigh: [Point] = [[0, -0.19], [0.085, -0.15], [0.092, 0.3], [0.066, 0.75], [0.054, 1], [0.052, 1.05],
                                         [-0.052, 1.05], [-0.054, 1], [-0.064, 0.7], [-0.088, 0.3], [-0.085, -0.15]]
    private static let shin: [Point] = [[0.052, -0.05], [0.052, 0.05], [0.05, 0.3], [0.04, 0.75], [0.036, 1], [0, 1.08],
                                        [-0.036, 1], [-0.045, 0.7], [-0.07, 0.3], [-0.056, 0.05], [-0.054, -0.05]]
    private static let upperArm: [Point] = [[0, -0.17], [0.055, -0.12], [0.052, 0.4], [0.04, 1], [0.04, 1.06],
                                            [-0.04, 1.06], [-0.04, 1], [-0.05, 0.45], [-0.055, -0.12]]
    private static let forearm: [Point] = [[0.04, -0.06], [0.04, 0.05], [0.045, 0.3], [0.03, 1], [-0.03, 1], [-0.042, 0.3],
                                           [-0.04, 0.05], [-0.04, -0.06]]
    /// (palm side, along the forearm) in metres from the grip.
    private static let fist: [Point] = [[0.032, -0.055], [0.05, 0], [0.036, 0.048], [0, 0.058], [-0.034, 0.046], [-0.042, 0],
                                        [-0.032, -0.055]]
    /// (forward, up) in metres from the wrist of a hand flat on the floor.
    private static let palm: [Point] = [[-0.04, 0.03], [0.06, 0.025], [0.15, 0], [0.15, -0.035], [-0.045, -0.035]]
    /// (forward, up) from the ankle, foot flat; in the front view (outward, up).
    private static let shoeSide: [Point] = [[-0.048, 0.035], [-0.07, -0.03], [-0.06, -0.078], [0.16, -0.078], [0.2, -0.062],
                                            [0.17, -0.03], [0.09, -0.004], [0.048, 0.035]]
    private static let shoeFront: [Point] = [[-0.045, 0.02], [0.045, 0.02], [0.085, -0.04], [0.07, -0.078], [-0.04, -0.078],
                                             [-0.055, -0.04]]

    /// Muscle bellies, in their body part's axes; the part's own outline cuts them.
    private static let trunkSide: [Belly] = [
        ([.glutes, .abductors], [-0.09, 0.02], [0.09, 0.11]), ([.hips], [0.08, 0], [0.06, 0.08]),
        ([.abs, .obliques], [0.08, 0.19], [0.07, 0.11]), ([.lowerBack], [-0.08, 0.19], [0.06, 0.1]),
        ([.chest], [0.09, 0.4], [0.09, 0.12]), ([.lats, .traps], [-0.09, 0.38], [0.08, 0.15])]
    private static let trunkFront: [Belly] = [
        ([.hips, .adductors, .abductors], [0, 0], [0.15, 0.08]), ([.abs, .obliques], [0, 0.19], [0.08, 0.1]),
        ([.chest], [-0.08, 0.42], [0.075, 0.07]), ([.chest], [0.08, 0.42], [0.075, 0.07]), ([.traps], [0, 0.56], [0.14, 0.05])]
    private static let thighSide: [Belly] = [([.quads], [0.06, 0.6], [0.05, 0.34]), ([.hamstrings], [-0.06, 0.6], [0.05, 0.34])]
    private static let thighFront: [Belly] = [([.quads], [0.015, 0.65], [0.07, 0.32]), ([.adductors], [-0.07, 0.6], [0.04, 0.25])]
    private static let shinBellies: [Belly] = [([.calves], [-0.05, 0.32], [0.045, 0.27])]
    private static let deltoid: Belly = ([.shoulders], [0, -0.02], [0.08, 0.3])
    private static let upperArmSide: [Belly] = [deltoid, ([.biceps], [0.05, 0.62], [0.04, 0.3]), ([.triceps], [-0.05, 0.62], [0.04, 0.3])]
    private static let upperArmFront: [Belly] = [deltoid, ([.biceps, .triceps], [0, 0.65], [0.08, 0.32])]
    private static let forearmBellies: [Belly] = [([.forearm], [0, 0.4], [0.08, 0.5])]

    static func draw(pose: ExercisePose, skeleton: ExercisePose.Skeleton, muscles: ExerciseMuscles,
                     in context: GraphicsContext, size: CGSize) {
        let frame = pose.framing.bounds, margin = 0.07
        let scale = min(size.width * (1 - 2 * margin) / frame.width, size.height * (1 - 2 * margin) / frame.height)
        guard scale.isFinite, scale > 0 else { return }
        var gc = context
        gc.translateBy(x: size.width / 2 - frame.midX * scale, y: size.height / 2 + frame.midY * scale)
        gc.scaleBy(x: scale, y: -scale)
        FigurePainter(gc: gc, pose: pose, sk: skeleton, muscles: muscles,
                      ow: min(max(size.width / 300, 0.6), 1.5) / scale).paint()
    }

    private var side: Bool { pose.camera == .side }

    /// Whether the hand hangs between the legs, inside the thigh at its own height: a
    /// sumo grip low between the knees, not the same grip at the hips.
    private func handInsideThigh(_ s: ExercisePose.Skeleton.Side) -> Bool {
        let t = min(max((s.hip.y - s.hand.y) / max(s.hip.y - s.knee.y, 1e-9), 0), 1)
        return s.hand.z < s.hip.z + (s.knee.z - s.hip.z) * t - 0.05
    }

    /// The point on the spine and neck closest to `q`: what decides whether `q` is in
    /// front of the body (a bar overhead is judged against the head, not the waist).
    private func nearestOnBody(_ q: SIMD3<Double>) -> SIMD3<Double> {
        let line = [sk.pelvis, sk.shoulders, sk.head]
        return zip(line, line.dropFirst()).map { a, b in
            a + (b - a) * min(max(simd_dot(q - a, b - a) / simd_length_squared(b - a), 0), 1)
        }.min { simd_distance($0, q) < simd_distance($1, q) }!
    }

    private func paint() {
        gc.fill(Path(ellipseIn: pose.framing.floor), with: .color(F.floor))
        let body = spine()
        let trunk = smooth((side ? Self.torsoSide : Self.torsoFront).map(body))
        let neck = Path { $0.move(to: cg(p(sk.shoulders + sk.up * 0.03))); $0.addLine(to: cg(p(sk.head))) }
            .strokedPath(StrokeStyle(lineWidth: 0.075, lineCap: .round))
        let head = circle(p(sk.head), Body.headRadius), core = [neck, head, trunk]
        let nearLeg = leg(sk.near), farLeg = leg(sk.far), nearArm = arm(sk.near), farArm = arm(sk.far)
        let figure = farLeg.paths + core + nearLeg.paths + nearArm.paths
        if side {
            let barInFront = sk.bar.map { pose.camera.depth($0) > pose.camera.depth(nearestOnBody($0)) }
            let armInsideKnee = handInsideThigh(sk.near)
            if let bar = sk.bar, barInFront == false { drawBar(bar) }
            dress(arm: farArm, sk.far, far: true, Self.heavy, on: nil)
            if let bench = pose.props.bench { drawPad(bench) }
            outline(figure, Self.heavy)
            outline(farLeg.paths)
            dress(leg: farLeg, sk.far, far: true)
            if let bench = pose.props.bench { drawFrame(bench) }
            outline(core + nearLeg.paths)
            headAndNeck(neck, head)
            torso(body, trunk)
            if armInsideKnee {
                dress(arm: nearArm, sk.near, far: false, on: trunk)
                outline(nearLeg.paths)
            }
            dress(leg: nearLeg, sk.near, far: false)
            if let bar = sk.bar, barInFront == true {
                drawBar(bar)
                solid([farArm.tip], shade(F.skin))
            }
            if !armInsideKnee { dress(arm: nearArm, sk.near, far: false, on: trunk) }
        } else {
            if let bench = pose.props.bench { drawFrame(bench); drawPad(bench) }
            outline(farArm.paths + figure, Self.heavy)
            outline(farLeg.paths + nearLeg.paths + core)
            dress(leg: farLeg, sk.far, far: false)
            dress(leg: nearLeg, sk.near, far: false)
            headAndNeck(neck, head)
            torso(body, trunk)
            dress(arm: farArm, sk.far, far: false, on: trunk)
            dress(arm: nearArm, sk.near, far: false, on: trunk)
        }
    }

    // MARK: Colour

    private func highlight(_ list: [GarminMuscle]) -> Color? {
        switch muscles.level(list) {
        case 2: Theme.Palette.Tissue.heavy
        case 1: Theme.Palette.Tissue.load(.moderate)
        default: nil
        }
    }

    private func shade(_ c: Color) -> Color { c.mix(with: F.outline, by: 0.3) }

    // MARK: Primitives

    private func p(_ v: SIMD3<Double>) -> Point { pose.camera.project(v) }

    private func cg(_ v: Point) -> CGPoint { CGPoint(x: v.x, y: v.y) }

    private func line(_ a: Point, _ b: Point, _ width: Double, _ c: Color, cap: CGLineCap = .round, on context: GraphicsContext? = nil) {
        (context ?? gc).stroke(Path { $0.move(to: cg(a)); $0.addLine(to: cg(b)) }, with: .color(c),
                               style: StrokeStyle(lineWidth: width, lineCap: cap))
    }

    private func circle(_ c: Point, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    private func disc(_ c: Point, _ r: Double, _ fill: Color) { gc.fill(circle(c, r), with: .color(fill)) }

    /// One outline around `paths` together: filled afterwards, no line shows where they
    /// overlap. Nor where they leave `body` inside `root` — a limb grows out of the trunk.
    private func outline(_ paths: [Path], _ weight: Double = thin, leaving body: Path? = nil, at root: Path = Path()) {
        gc.drawLayer { layer in
            for path in paths {
                layer.stroke(path, with: .color(F.outline), style: StrokeStyle(lineWidth: 2 * weight * ow, lineJoin: .round))
            }
            guard let body else { return }
            layer.clip(to: body)
            layer.blendMode = .destinationOut
            layer.fill(root, with: .color(.black))
        }
    }

    private func solid(_ paths: [Path], _ fill: Color) {
        outline(paths, 1)
        for path in paths { gc.fill(path, with: .color(fill)) }
    }

    private func polygon(_ points: [Point]) -> Path {
        Path { $0.addLines(points.map(cg)); $0.closeSubpath() }
    }

    /// A closed curve through the midpoints of `points`, each point its control.
    private func smooth(_ points: [Point]) -> Path {
        Path { path in
            let mid = { (a: Point, b: Point) in self.cg((a + b) / 2) }
            path.move(to: mid(points[points.count - 1], points[0]))
            for (i, point) in points.enumerated() {
                path.addQuadCurve(to: mid(point, points[(i + 1) % points.count]), control: cg(point))
            }
            path.closeSubpath()
        }
    }

    private func normalized(_ v: Point) -> Point { v / max((v * v).sum().squareRoot(), 1e-9) }

    private func turnedLeft(_ v: Point) -> Point { [-v.y, v.x] }

    /// `shape` in `cloth` up to `hem` along `map` and in `rest` beyond.
    private func clothe(_ shape: Path, _ map: Map, _ cloth: Color, to hem: Double, then rest: Color) {
        var inner = gc
        inner.clip(to: shape)
        inner.fill(polygon([[-0.4, hem], [0.4, hem], [0.4, -2], [-0.4, -2]].map(map)), with: .color(cloth))
        inner.fill(polygon([[-0.4, hem], [0.4, hem], [0.4, 2], [-0.4, 2]].map(map)), with: .color(rest))
    }

    /// The worked muscles among `bellies` on `shape`, then the hem line across it.
    private func tint(_ shape: Path, _ map: Map, _ bellies: [Belly], far: Bool = false, hem: Double? = nil) {
        var inner = gc
        inner.clip(to: shape)
        for belly in bellies {
            guard let c = highlight(belly.muscles) else { continue }
            let oval = (0..<16).map { i -> Point in
                let a = Double(i) * .pi / 8
                return map(belly.center + belly.radius * [cos(a), sin(a)])
            }
            inner.fill(smooth(oval), with: .color(far ? shade(c) : c))
        }
        if let hem { line(map([-0.4, hem]), map([0.4, hem]), Self.thin * ow, F.outline, cap: .butt, on: inner) }
    }

    // MARK: Body

    /// The trunk's axes along the spine, pelvis to shoulders. Standing, the lower back
    /// is hollow; the arch flattens as the hips fold, gone at a right angle.
    private func spine() -> Map {
        let a = p(sk.pelvis), c = p(sk.shoulders), length = simd_length(c - a), up = (c - a) / length
        let fold = 1 + simd_dot(sk.up, simd_normalize(sk.near.knee - sk.near.hip))
        let b = (a + c) / 2 + SIMD2(up.y, -up.x) * (side ? 0.04 * max(0, 1 - fold) : 0)
        return { q in
            let t = q.y / Body.torso, u = min(max(t, 0), 1)
            let along = simd_normalize((b - a) * (1 - u) + (c - b) * u)
            let on = a * ((1 - u) * (1 - u)) + b * (2 * u * (1 - u)) + c * (u * u)
            return on + along * ((t - u) * length) + SIMD2(along.y, -along.x) * q.x
        }
    }

    /// A two-segment limb a → b → c, its outlines' front on the `flip` side.
    private func limb(_ a: Point, _ b: Point, _ c: Point, flip: Double, _ upper: [Point], _ lower: [Point], joint: Double,
                      tip: (Frame) -> Path) -> Limb {
        let root = Frame(origin: a, front: turnedLeft(normalized(b - a)) * flip, up: b - a)
        let end = Frame(origin: b, front: turnedLeft(normalized(c - b)) * flip, up: c - b)
        return Limb(root: root, end: end, upper: smooth(upper.map(root.callAsFunction)), lower: smooth(lower.map(end.callAsFunction)),
                    joint: circle(b, joint), tip: tip(end))
    }

    /// The shoe's own (forward, up) axes from the ankle; in the front view the toes turn out.
    private func foot(_ s: ExercisePose.Skeleton.Side) -> Map {
        let r = s.footAngle * .pi / 180, (cosA, sinA) = (cos(r), sin(r)), a = s.ankle
        return side ? { q in self.p([a.x + q.x * cosA - q.y * sinA, a.y + q.x * sinA + q.y * cosA, a.z]) }
                    : { q in self.p(a) + [q.x * s.sign, q.y] }
    }

    private func leg(_ s: ExercisePose.Skeleton.Side) -> Limb {
        limb(p(s.hip), p(s.knee), p(s.ankle), flip: side ? 1 : s.sign, Self.thigh, Self.shin, joint: 0.053) { _ in
            smooth((side ? Self.shoeSide : Self.shoeFront).map(foot(s)))
        }
    }

    private func dress(leg: Limb, _ s: ExercisePose.Skeleton.Side, far: Bool) {
        let skin = far ? shade(F.skin) : F.skin
        gc.fill(leg.joint, with: .color(skin))
        clothe(leg.upper, leg.root.callAsFunction, far ? shade(F.shorts) : F.shorts, to: 0.45, then: skin)
        tint(leg.upper, leg.root.callAsFunction, side ? Self.thighSide : Self.thighFront, far: far, hem: 0.45)
        gc.fill(leg.lower, with: .color(skin))
        tint(leg.lower, leg.end.callAsFunction, Self.shinBellies, far: far)
        gc.fill(leg.tip, with: .color(far ? shade(F.shoe) : F.shoe))
        var sole = gc
        sole.clip(to: leg.tip)
        sole.fill(polygon([[-0.2, -0.058], [0.3, -0.058], [0.3, -0.2], [-0.2, -0.2]].map(foot(s))), with: .color(far ? shade(F.metal) : F.metal))
    }

    /// A hand closes to a fist around whatever it holds; on the floor it lies flat.
    private func arm(_ s: ExercisePose.Skeleton.Side) -> Limb {
        let a = p(s.shoulder), b = p(s.elbow), c = p(s.hand)
        let bend = simd_dot(c - b, turnedLeft(normalized(b - a))) < 0 ? -1.0 : 1.0
        let flat = pose.props.barbell == nil && pose.props.dumbbells != true && s.hand.y < 0.1
        return limb(a, b, c, flip: bend, Self.upperArm, Self.forearm, joint: 0.04) { forearm in
            flat ? smooth(Self.palm.map { q in p(s.hand + SIMD3(q.x, q.y, 0)) })
                 : smooth(Self.fist.map(Frame(origin: c, front: forearm.front, up: normalized(c - b)).callAsFunction))
        }
    }

    /// An arm, growing out of `trunk` when it lies in front of it.
    private func dress(arm: Limb, _ s: ExercisePose.Skeleton.Side, far: Bool, _ weight: Double = thin, on trunk: Path?) {
        let skin = far ? shade(F.skin) : F.skin
        if pose.props.dumbbells == true { dumbbell(s, far: far, front: false) }
        outline(arm.paths, weight, leaving: trunk, at: circle(p(s.shoulder), 0.1))
        gc.fill(arm.joint, with: .color(skin))
        clothe(arm.upper, arm.root.callAsFunction, far ? shade(F.shirt) : F.shirt, to: 0.32, then: skin)
        tint(arm.upper, arm.root.callAsFunction, side ? Self.upperArmSide : Self.upperArmFront, far: far, hem: 0.32)
        gc.fill(arm.lower, with: .color(skin))
        tint(arm.lower, arm.end.callAsFunction, Self.forearmBellies, far: far)
        gc.fill(arm.tip, with: .color(skin))
        if pose.props.dumbbells == true { dumbbell(s, far: far, front: true) }
    }

    private func torso(_ body: Map, _ trunk: Path) {
        clothe(trunk, body, F.shorts, to: 0.115, then: F.shirt)
        tint(trunk, body, side ? Self.trunkSide : Self.trunkFront, hem: 0.115)
    }

    private func headAndNeck(_ neck: Path, _ head: Path) {
        gc.fill(neck, with: .color(F.skin))
        gc.fill(head, with: .color(F.hair))
        let center = p(sk.head), up = normalized(center - p(sk.shoulders)), front: Point = [up.y, -up.x]
        var inner = gc
        inner.clip(to: head)
        inner.fill(circle(side ? center + front * 0.06 - up * 0.05 : center - up * 0.035, 0.11), with: .color(F.skin))
    }

    // MARK: Props

    /// The circle of `radius` around the bar's axis at `z`, as the camera sees it; with
    /// `front`, only the half facing the viewer.
    private func ring(_ bar: SIMD3<Double>, _ z: Double, _ radius: Double, front: Bool = false) -> Path {
        let c = SIMD3(bar.x, bar.y, z), t0 = atan2(pose.camera.depth([0, 1, 0]), pose.camera.depth([1, 0, 0]))
        return Path { path in
            path.addLines((0...24).map { i in
                let t = front ? t0 + Double.pi * (Double(i) / 24 - 0.5) : Double.pi * Double(i) / 12
                return cg(p(c + SIMD3(cos(t), sin(t), 0) * radius))
            })
            if !front { path.closeSubpath() }
        }
    }

    /// The bar from `z0` to `z1` as a cylinder: both end circles and the band between.
    private func tube(_ bar: SIMD3<Double>, _ z0: Double, _ z1: Double, _ radius: Double) -> [Path] {
        let a = p([bar.x, bar.y, z0]), b = p([bar.x, bar.y, z1]), n = turnedLeft(normalized(b - a))
        let half = radius * simd_length(SIMD2(simd_dot(p([1, 0, 0]) - p(.zero), n), simd_dot(p([0, 1, 0]) - p(.zero), n)))
        return [ring(bar, z0, radius), ring(bar, z1, radius), polygon([a + n * half, b + n * half, b - n * half, a - n * half])]
    }

    /// Shaft and sleeves as one piece of metal, the near sleeve's end face showing, and a
    /// ring at each collar that the bar hides where the ring passes behind it.
    private func drawBar(_ bar: SIMD3<Double>) {
        let ends = [-1.0, 1.0], collar = 0.61, sleeve = 0.025
        func rings(front: Bool) {
            for end in ends {
                let r = ring(bar, end * collar, 0.042, front: front)
                gc.stroke(r, with: .color(F.outline), style: StrokeStyle(lineWidth: 0.014 + 2 * ow, lineCap: .butt))
                gc.stroke(r, with: .color(F.metal), style: StrokeStyle(lineWidth: 0.014, lineCap: .butt))
            }
        }
        rings(front: false)
        solid(tube(bar, -collar, collar, 0.014) + ends.flatMap { tube(bar, $0 * collar, $0 * Body.barHalfLength, sleeve) }, F.metal)
        let face = pose.camera.depth([0, 0, 1]) > 0 ? 1.0 : -1.0
        gc.stroke(ring(bar, face * Body.barHalfLength, sleeve), with: .color(F.outline), lineWidth: Self.thin * ow)
        rings(front: true)
    }

    private func dumbbell(_ s: ExercisePose.Skeleton.Side, far: Bool, front: Bool) {
        let h = s.hand, z = Body.dumbbellPlateZ, plate = far ? shade(F.plate) : F.plate
        let at = { (dz: Double) in self.p([h.x, h.y, h.z + dz]) }
        func handle() {
            line(at(-z), at(z), 0.03 + 2 * ow, F.outline)
            line(at(-z), at(z), 0.03, F.metal)
        }
        func plateDisc(_ c: Point) {
            disc(c, 0.065 + ow, F.outline)
            disc(c, 0.065, plate)
            disc(c, 0.018, F.metal)
        }
        if side {
            if front { plateDisc(at(z)) } else { plateDisc(at(-z)); handle() }
        } else if front {
            handle()
            for c in [at(-z), at(z)] {
                solid([Path(roundedRect: CGRect(x: c.x - 0.026, y: c.y - 0.07, width: 0.052, height: 0.14), cornerRadius: 0.015)], plate)
            }
        }
    }

    /// The legs, drawn after the far leg (its foot stands behind them) but kept under the pad.
    private func drawFrame(_ bench: ExercisePose.Bench) {
        var frame = gc
        for face in pad(bench) { frame.clip(to: face, options: .inverse) }
        let legs = [bench.x.x + 0.1, bench.x.y - 0.1]
        for x in legs {
            let a = p([x, 0.02, -0.2]), b = p([x, 0.02, 0.2])
            line(a, b, 0.04 + 2 * ow, F.outline, cap: .butt, on: frame)
            line(a, b, 0.04, F.metal, cap: .butt, on: frame)
        }
        for z in [-0.1, 0.1] {
            for x in legs {
                let a = p([x, 0.02, z]), b = p([x, bench.top - 0.09, z])
                line(a, b, 0.05 + 2 * ow, F.outline, cap: .butt, on: frame)
                line(a, b, 0.05, z < 0 ? shade(F.metal) : F.metal, cap: .butt, on: frame)
            }
        }
    }

    /// The pad's top, head end and near side.
    private func pad(_ bench: ExercisePose.Bench) -> [Path] {
        let x0 = bench.x.x, x1 = bench.x.y, top = bench.top, bottom = top - 0.09, w = 0.14
        return [polygon([p([x0, top, -w]), p([x1, top, -w]), p([x1, top, w]), p([x0, top, w])]),
                polygon([p([x0, top, -w]), p([x0, top, w]), p([x0, bottom, w]), p([x0, bottom, -w])]),
                polygon([p([x0, top, w]), p([x1, top, w]), p([x1, bottom, w]), p([x0, bottom, w])])]
    }

    private func drawPad(_ bench: ExercisePose.Bench) {
        for (face, fill) in zip(pad(bench), [F.pad, shade(shade(F.pad)), shade(F.pad)]) { solid([face], fill) }
    }
}
