import SwiftUI

// MARK: - Exercise animation
//
// One exercise's rep, looped at its tempo. `ExercisePose` places the skeleton; this
// only draws it, Garmin style: a grey figure in shirt and shorts with a dark outline,
// far-side limbs a shade darker, props as plain shapes, and the worked muscles in the
// Tissue Load reds (primary heavy, secondary moderate).
//
// Muscles are clipped ellipses and rounded half-limb strokes — never rectangles: a
// straight edge across the body reads as clothing. The near barbell plate is see-through
// so it never hides the lifter.

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

    private enum Width {
        static let upperArm = 0.1, forearm = 0.085, thigh = 0.15, shin = 0.11, neck = 0.085, hand = 0.045
    }

    /// (front, up) in metres from the pelvis, along the torso.
    private static let torsoSide: [Point] = [[-0.13, -0.07], [0.1, -0.08], [0.115, 0.12], [0.11, 0.26], [0.14, 0.4], [0.1, 0.5],
                                             [0, 0.565], [-0.1, 0.525], [-0.125, 0.38], [-0.1, 0.2], [-0.145, 0.05]]
    private static let torsoFront: [Point] = [[0.17, -0.08], [0.185, 0.06], [0.15, 0.22], [0.17, 0.36], [0.22, 0.47], [0.2, 0.54],
                                              [0.07, 0.585], [-0.07, 0.585], [-0.2, 0.54], [-0.22, 0.47], [-0.17, 0.36],
                                              [-0.15, 0.22], [-0.185, 0.06], [-0.17, -0.08], [0, -0.06]]
    /// (forward, up) from the ankle, foot flat.
    private static let shoe: [Point] = [[-0.045, 0.03], [-0.065, -0.04], [-0.045, -0.075], [0.15, -0.075],
                                        [0.178, -0.052], [0.12, -0.018], [0.045, 0.03]]

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

    private func paint() {
        let floor = pose.framing.floor
        gc.fill(Path(ellipseIn: CGRect(x: floor.lowerBound, y: -0.04, width: floor.upperBound - floor.lowerBound, height: 0.08)),
                with: .color(F.floor))
        if let bench = pose.props.bench { drawBench(bench) }
        if side {
            if let bar = sk.bar {
                farPlate(bar)
                barSegment(bar, -0.5, -0.17, 0.028)
                barSegment(bar, -0.5, -0.46, 0.075)
            }
            arm(sk.far, far: true)
            leg(sk.far, far: true)
            neckAndHead()
            torso()
            leg(sk.near, far: false)
            if let bar = sk.bar {
                barSegment(bar, -0.17, 0.42, 0.028)
                barSegment(bar, 0.42, Body.plateZ, 0.05)
                barSegment(bar, 0.42, 0.46, 0.075)
            }
            arm(sk.near, far: false)
            if let bar = sk.bar { nearPlate(bar) }
        } else {
            leg(sk.far, far: false)
            leg(sk.near, far: false)
            neckAndHead()
            torso()
            arm(sk.far, far: false)
            arm(sk.near, far: false)
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

    private func color(_ list: [GarminMuscle], else base: Color, far: Bool) -> Color {
        let c = highlight(list) ?? base
        return far ? shade(c) : c
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

    private func outlined(_ path: Path, _ fill: Color) {
        gc.fill(path, with: .color(fill))
        gc.stroke(path, with: .color(F.outline), style: StrokeStyle(lineWidth: 1.3 * ow, lineJoin: .round))
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

    /// One muscle as a rounded stroke along half a limb segment, on the `normal` side.
    private func half(_ a: Point, _ b: Point, width: Double, normal: Point, _ muscle: GarminMuscle, far: Bool,
                      from t0: Double, to t1: Double) {
        guard let c = highlight([muscle]) else { return }
        let d = b - a, offset = normal * (width / 4)
        line(a + offset + d * t0, a + offset + d * t1, width / 2, far ? shade(c) : c)
    }

    // MARK: Body

    private func leg(_ s: ExercisePose.Skeleton.Side, far: Bool) {
        let a = p(s.hip), b = p(s.knee), c = p(s.ankle), skin = far ? shade(F.skin) : F.skin
        let thighNormal = turnedLeft(normalized(b - a)), shinNormal = turnedLeft(normalized(c - b))
        line(a, b, Width.thigh + 2 * ow, F.outline)
        line(b, c, Width.shin + 2 * ow, F.outline)
        line(b, c, Width.shin, skin)
        line(a, b, Width.thigh, side ? skin : color([.quads], else: F.skin, far: far))
        if side {
            half(a, b, width: Width.thigh, normal: thighNormal, .quads, far: far, from: 0.36, to: 0.88)
            half(a, b, width: Width.thigh, normal: -thighNormal, .hamstrings, far: far, from: 0.36, to: 0.88)
            half(b, c, width: Width.shin, normal: -shinNormal, .calves, far: far, from: 0.12, to: 0.6)
        } else {
            half(a, b, width: Width.thigh, normal: thighNormal * -s.sign, .adductors, far: far, from: 0.36, to: 0.85)
        }
        let shorts = far ? shade(F.shorts) : F.shorts, hem = a + (b - a) * 0.34
        line(a, hem, Width.thigh, shorts, cap: .butt)
        disc(a, Width.thigh / 2, shorts)
        line(hem + thighNormal * (Width.thigh / 2), hem - thighNormal * (Width.thigh / 2), ow, F.outline, cap: .butt)
        shoe(s, far: far)
    }

    private func shoe(_ s: ExercisePose.Skeleton.Side, far: Bool) {
        let fill = far ? shade(F.shoe) : F.shoe
        if side {
            let r = s.footAngle * .pi / 180, (cosA, sinA) = (cos(r), sin(r)), a = s.ankle
            outlined(smooth(Self.shoe.map { q in p([a.x + q.x * cosA - q.y * sinA, a.y + q.x * sinA + q.y * cosA, a.z]) }), fill)
        } else {
            let c = p(s.ankle)
            outlined(Path(roundedRect: CGRect(x: c.x - 0.055, y: c.y - 0.085, width: 0.11, height: 0.1), cornerRadius: 0.03), fill)
        }
    }

    private func arm(_ s: ExercisePose.Skeleton.Side, far: Bool) {
        let a = p(s.shoulder), b = p(s.elbow), c = p(s.hand), skin = far ? shade(F.skin) : F.skin
        let deltoid = highlight([.shoulders]).map { far ? shade($0) : $0 }
        if pose.props.dumbbells == true { dumbbell(s, far: far, front: false) }
        line(a, b, Width.upperArm + 2 * ow, F.outline)
        line(b, c, Width.forearm + 2 * ow, F.outline)
        disc(c, Width.hand + ow, F.outline)
        if deltoid != nil { disc(a, 0.06 + ow, F.outline) }
        line(a, b, Width.upperArm, side ? skin : color([.biceps, .triceps], else: F.skin, far: far))
        line(b, c, Width.forearm, color([.forearm], else: F.skin, far: far))
        if side {
            var bicepsSide = turnedLeft(normalized(b - a))
            if ((c - b) * bicepsSide).sum() < 0 { bicepsSide = -bicepsSide }
            half(a, b, width: Width.upperArm, normal: bicepsSide, .biceps, far: far, from: 0.15, to: 0.85)
            half(a, b, width: Width.upperArm, normal: -bicepsSide, .triceps, far: far, from: 0.15, to: 0.85)
        }
        disc(c, Width.hand, skin)
        if let deltoid { disc(a, 0.06, deltoid) }
        if pose.props.dumbbells == true { dumbbell(s, far: far, front: true) }
    }

    private func torso() {
        let pelvis = p(sk.pelvis), axis = p(sk.shoulders) - pelvis
        let stretch = (axis * axis).sum().squareRoot() / Body.torso, up = normalized(axis), front: Point = [up.y, -up.x]
        let local = { (q: Point) in pelvis + front * q.x + up * (q.y * stretch) }
        let outline = smooth((side ? Self.torsoSide : Self.torsoFront).map(local))
        gc.fill(outline, with: .color(F.shirt))
        var inner = gc
        inner.clip(to: outline)
        inner.fill(polygon([[-0.4, -0.3], [0.4, -0.3], [0.4, 0.115], [-0.4, 0.115]].map(local)), with: .color(F.shorts))
        line(local([-0.4, 0.115]), local([0.4, 0.115]), ow, F.outline, cap: .butt, on: inner)
        let toBody = CGAffineTransform(a: front.x, b: front.y, c: up.x * stretch, d: up.y * stretch, tx: pelvis.x, ty: pelvis.y)
        func belly(_ list: [GarminMuscle], _ center: Point, _ radius: Point) {
            guard let c = highlight(list) else { return }
            let oval = CGRect(x: center.x - radius.x, y: center.y - radius.y, width: 2 * radius.x, height: 2 * radius.y)
            inner.fill(Path(ellipseIn: oval).applying(toBody), with: .color(c))
        }
        if side {
            belly([.glutes, .abductors], [-0.09, 0.02], [0.09, 0.11])
            belly([.hips], [0.08, 0], [0.06, 0.08])
            belly([.abs, .obliques], [0.09, 0.19], [0.07, 0.11])
            belly([.lowerBack], [-0.08, 0.19], [0.06, 0.1])
            belly([.chest], [0.1, 0.4], [0.09, 0.12])
            belly([.lats, .traps], [-0.09, 0.38], [0.08, 0.15])
        } else {
            belly([.hips, .adductors, .abductors], [0, 0], [0.15, 0.08])
            belly([.abs, .obliques], [0, 0.19], [0.08, 0.1])
            belly([.chest], [-0.085, 0.42], [0.08, 0.07])
            belly([.chest], [0.085, 0.42], [0.08, 0.07])
            belly([.traps], [0, 0.56], [0.16, 0.05])
        }
        gc.stroke(outline, with: .color(F.outline), lineWidth: 1.3 * ow)
    }

    private func neckAndHead() {
        let neck = p(sk.shoulders + sk.up * 0.03), center = p(sk.head)
        line(neck, center, Width.neck + 2 * ow, F.outline)
        line(neck, center, Width.neck, F.skin)
        let up = normalized(center - p(sk.shoulders)), front: Point = [up.y, -up.x]
        let head = circle(center, Body.headRadius)
        gc.fill(head, with: .color(F.hair))
        var inner = gc
        inner.clip(to: head)
        let face = side ? center + front * 0.035 - up * 0.03 : center - up * 0.035
        inner.fill(circle(face, 0.108), with: .color(F.skin))
        if side { inner.fill(circle(center - front * 0.012 - up * 0.01, 0.022), with: .color(shade(F.skin))) }
        gc.stroke(head, with: .color(F.outline), lineWidth: 1.3 * ow)
    }

    // MARK: Props

    private func barSegment(_ bar: SIMD3<Double>, _ z0: Double, _ z1: Double, _ width: Double) {
        let a = p([bar.x, bar.y, z0]), b = p([bar.x, bar.y, z1])
        line(a, b, width + 2 * ow, F.outline, cap: .butt)
        line(a, b, width, F.metal, cap: .butt)
    }

    private func hub(_ c: Point) {
        disc(c, 0.035 + ow, F.outline)
        disc(c, 0.035, F.metal)
    }

    private func farPlate(_ bar: SIMD3<Double>) {
        let c = p([bar.x, bar.y, -Body.plateZ])
        disc(c, Body.plateRadius + ow, F.outline)
        disc(c, Body.plateRadius, F.plate)
        gc.stroke(circle(c, 0.15), with: .color(shade(F.plate)), lineWidth: ow)
        hub(c)
    }

    private func nearPlate(_ bar: SIMD3<Double>) {
        let c = p([bar.x, bar.y, Body.plateZ])
        var faint = gc
        faint.opacity = 0.3
        faint.fill(circle(c, Body.plateRadius), with: .color(F.plate))
        gc.stroke(circle(c, 0.21), with: .color(F.plate), lineWidth: 0.03)
        for r in [Body.plateRadius, 0.195] { gc.stroke(circle(c, r), with: .color(F.outline), lineWidth: ow) }
        hub(c)
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
                outlined(Path(roundedRect: CGRect(x: c.x - 0.026, y: c.y - 0.07, width: 0.052, height: 0.14), cornerRadius: 0.015), plate)
            }
        }
    }

    private func drawBench(_ bench: ExercisePose.Bench) {
        let x0 = bench.x.x, x1 = bench.x.y, top = bench.top, halfWidth = 0.14, thickness = 0.09
        let legs = [x0 + 0.1, x1 - 0.1]
        for x in legs {
            let a = p([x, 0.02, -0.2]), b = p([x, 0.02, 0.2])
            line(a, b, 0.04 + 2 * ow, F.outline, cap: .butt)
            line(a, b, 0.04, F.metal, cap: .butt)
        }
        for z in [-0.1, 0.1] {
            for x in legs {
                let a = p([x, 0.02, z]), b = p([x, top - thickness, z])
                line(a, b, 0.05 + 2 * ow, F.outline, cap: .butt)
                line(a, b, 0.05, z < 0 ? shade(F.metal) : F.metal, cap: .butt)
            }
        }
        let padSide = shade(F.pad)
        outlined(polygon([p([x0, top, -halfWidth]), p([x1, top, -halfWidth]), p([x1, top, halfWidth]), p([x0, top, halfWidth])]), F.pad)
        outlined(polygon([p([x0, top, -halfWidth]), p([x0, top, halfWidth]), p([x0, top - thickness, halfWidth]),
                          p([x0, top - thickness, -halfWidth])]), shade(padSide))
        outlined(polygon([p([x0, top, halfWidth]), p([x1, top, halfWidth]), p([x1, top - thickness, halfWidth]),
                          p([x0, top - thickness, halfWidth])]), padSide)
    }
}
