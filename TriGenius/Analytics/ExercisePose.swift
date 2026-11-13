import CoreGraphics
import Foundation
import simd

// MARK: - Exercise poses
//
// The keyframes behind an exercise's animation (`Assets/Exercises/exercise-poses.json`,
// keyed by `Exercise.id`) and the one function that turns them into a skeleton at a
// point in the rep. Metres, floor at y = 0, the figure faces +x, z points at the viewer.
//
// Elbows and knees are never stored: two-bone IK places them from the hand and foot
// targets, so hands stay on the bar and feet stay planted between keyframes. Keyframes
// blend along a Catmull-Rom curve, and a straight blend between two keyframes is a
// chord: an arc (a raise) or a hinge needs a middle keyframe, or the hands fall short.

nonisolated struct ExercisePose: Decodable, Sendable {
    nonisolated enum Camera: String, Decodable, Sendable {
        /// A mild oblique: the near side (z > 0) shifts right and down.
        case side
        case front

        func project(_ p: SIMD3<Double>) -> SIMD2<Double> {
            switch self {
            case .side: return [p.x + 0.28 * p.z, p.y - 0.16 * p.z]
            case .front: return [p.z, p.y]
            }
        }
    }

    nonisolated enum Barbell: String, Decodable, Sendable {
        /// On the upper back; the hands reach for it.
        case back
        /// Held: it sits between the hands, wherever they are.
        case hands
    }

    nonisolated struct Bench: Decodable, Sendable {
        /// Pad start and end along x.
        var x: SIMD2<Double>
        var top: Double
    }

    nonisolated struct Props: Decodable, Sendable {
        var barbell: Barbell?
        var dumbbells: Bool?
        var bench: Bench?
    }

    nonisolated struct Hints: Decodable, Sendable {
        /// The side of the shoulder→hand and hip→ankle line the elbow and knee bend to,
        /// for the near side; the far side mirrors z.
        var elbow: SIMD3<Double>
        var knee: SIMD3<Double>
    }

    nonisolated enum Hand: Decodable, Sendable {
        /// On a barbell carried on the back.
        case bar
        /// [x, y] at the pose's grip width, or [x, y, z].
        case point([Double])

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if (try? c.decode(String.self)) == "bar" {
                self = .bar
            } else {
                self = .point(try c.decode([Double].self))
            }
        }
    }

    nonisolated struct Keyframe: Decodable, Sendable {
        var pelvis: SIMD2<Double>
        /// Pelvis → shoulders, degrees from +x.
        var torso: Double
        /// Shoulders → head centre, degrees from +x.
        var head: Double
        var hand: Hand
        /// Ankle x, ankle y, foot angle (degrees, 0 flat).
        var foot: SIMD3<Double>
    }

    var camera: Camera
    var props: Props
    /// Half the distance between the hands, where a keyframe's hand gives no z.
    var grip: Double
    /// Half the distance between the feet.
    var stance: Double
    var hints: Hints
    /// Seconds: out to the last keyframe, hold, back to the first, hold.
    var tempo: SIMD4<Double>
    var keyframes: [Keyframe]
    private(set) var framing = Framing(bounds: .zero, floor: 0...0)

    private enum CodingKeys: String, CodingKey { case camera, props, grip, stance, hints, tempo, keyframes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        camera = try c.decode(Camera.self, forKey: .camera)
        props = try c.decodeIfPresent(Props.self, forKey: .props) ?? Props()
        grip = try c.decode(Double.self, forKey: .grip)
        stance = try c.decode(Double.self, forKey: .stance)
        hints = try c.decode(Hints.self, forKey: .hints)
        tempo = try c.decode(SIMD4<Double>.self, forKey: .tempo)
        keyframes = try c.decode([Keyframe].self, forKey: .keyframes)
        if let problem = Self.problem(camera: camera, props: props, tempo: tempo, keyframes: keyframes) {
            throw DecodingError.dataCorruptedError(forKey: .keyframes, in: c, debugDescription: problem)
        }
        framing = Framing(of: self)
    }

    private static func problem(camera: Camera, props: Props, tempo: SIMD4<Double>, keyframes: [Keyframe]) -> String? {
        guard let first = keyframes.first else { return "no keyframes" }
        if tempo.sum() <= 0 { return "tempo sums to zero" }
        if props.barbell != nil && camera != .side { return "a barbell is drawn in the side view only" }
        for keyframe in keyframes {
            switch (first.hand, keyframe.hand) {
            case (.bar, .bar):
                if props.barbell != .back { return "hand \"bar\" needs a barbell on the back" }
            case (.point(let a), .point(let b)):
                if a.count != b.count || !(2...3).contains(b.count) { return "hands need the same [x, y] or [x, y, z] in every keyframe" }
            default:
                return "hands mix \"bar\" and points"
            }
        }
        return nil
    }

    // MARK: Time

    /// Where the rep stands `seconds` into the loop: 0 at the first keyframe, 1 at the
    /// last, eased in and out of each move.
    func progress(at seconds: Double) -> Double {
        let total = tempo.sum()
        var t = seconds.truncatingRemainder(dividingBy: total)
        if t < 0 { t += total }
        let ease = { (x: Double) in 0.5 - 0.5 * cos(.pi * x) }
        if t < tempo[0] { return ease(t / tempo[0]) }
        t -= tempo[0]
        if t < tempo[1] { return 1 }
        t -= tempo[1]
        if t < tempo[2] { return 1 - ease(t / tempo[2]) }
        return 0
    }

    // MARK: Skeleton

    nonisolated enum Body {
        static let torso = 0.5
        static let neckToHead = 0.2
        static let headRadius = 0.11
        static let upperArm = 0.3
        static let forearm = 0.33
        static let thigh = 0.44
        static let shin = 0.44
        static let shoulderHalfWidth = 0.19
        static let hipHalfWidth = 0.09
        static let plateRadius = 0.225
        static let plateZ = 0.52
        static let dumbbellPlateZ = 0.09
    }

    nonisolated struct Skeleton: Sendable {
        nonisolated struct Side: Sendable {
            /// +1 near, −1 far.
            var sign: Double
            var shoulder, elbow, hand, hip, knee, ankle: SIMD3<Double>
            /// Where the IK aimed; equal to `hand`/`ankle` unless out of reach.
            var handTarget, ankleTarget: SIMD3<Double>
            var footAngle: Double
        }

        var pelvis, shoulders, head: SIMD3<Double>
        /// Pelvis → shoulders, unit length.
        var up: SIMD3<Double>
        var bar: SIMD3<Double>?
        var near, far: Side
    }

    func skeleton(at progress: Double) -> Skeleton {
        let k = Self.blend(keyframes, at: progress * Double(keyframes.count - 1))
        let pelvis = SIMD3(k.pelvis.x, k.pelvis.y, 0)
        let up = Self.direction(k.torso), front = Self.direction(k.torso - 90)
        let shoulders = pelvis + up * Body.torso
        let barOnBack = shoulders - front * 0.1 + up * 0.02
        let sides = [1.0, -1.0].map { s -> Skeleton.Side in
            let mirror = SIMD3(1, 1, s)
            let hand: SIMD3<Double> = switch k.hand {
            case .bar: [barOnBack.x, barOnBack.y, grip]
            case .point(let p): [p[0], p[1], p.count > 2 ? p[2] : grip]
            }
            let handTarget = hand * mirror, ankleTarget = SIMD3(k.foot.x, k.foot.y, stance) * mirror
            let shoulder = SIMD3(shoulders.x, shoulders.y, s * Body.shoulderHalfWidth)
            let hip = SIMD3(pelvis.x, pelvis.y, s * Body.hipHalfWidth)
            let arm = Self.twoBone(root: shoulder, target: handTarget, Body.upperArm, Body.forearm, hint: hints.elbow * mirror)
            let leg = Self.twoBone(root: hip, target: ankleTarget, Body.thigh, Body.shin, hint: hints.knee * mirror)
            return .init(sign: s, shoulder: shoulder, elbow: arm.joint, hand: arm.end, hip: hip, knee: leg.joint,
                         ankle: leg.end, handTarget: handTarget, ankleTarget: ankleTarget, footAngle: k.foot.z)
        }
        let bar: SIMD3<Double>? = switch props.barbell {
        case .back: barOnBack
        case .hands: [(sides[0].hand.x + sides[1].hand.x) / 2, (sides[0].hand.y + sides[1].hand.y) / 2, 0]
        case nil: nil
        }
        return Skeleton(pelvis: pelvis, shoulders: shoulders, head: shoulders + Self.direction(k.head) * Body.neckToHead,
                        up: up, bar: bar, near: sides[0], far: sides[1])
    }

    /// The middle joint of a two-segment limb reaching from `root` toward `target`, on
    /// the side `hint` points to. An unreachable target leaves the limb straight toward it.
    static func twoBone(root: SIMD3<Double>, target: SIMD3<Double>, _ l1: Double, _ l2: Double,
                        hint: SIMD3<Double>) -> (joint: SIMD3<Double>, end: SIMD3<Double>) {
        let d = target - root, distance = simd_length(d)
        let axis = distance > 1e-9 ? d / distance : SIMD3(0, -1, 0)
        let reach = min(max(distance, abs(l1 - l2) + 1e-4), l1 + l2 - 1e-4)
        let cosA = (l1 * l1 + reach * reach - l2 * l2) / (2 * l1 * reach)
        let sinA = max(0, 1 - cosA * cosA).squareRoot()
        var bend = hint - axis * simd_dot(hint, axis)
        if simd_length(bend) < 1e-9 { bend = simd_cross(axis, SIMD3(0, 0, 1)) }
        bend = simd_normalize(bend)
        return (root + axis * (l1 * cosA) + bend * (l1 * sinA), root + axis * reach)
    }

    /// The keyframe at `u` (0 = first, count − 1 = last) on a Catmull-Rom curve through all.
    static func blend(_ k: [Keyframe], at u: Double) -> Keyframe {
        guard k.count > 1 else { return k[0] }
        let i = min(max(Int(u), 0), k.count - 2), t = u - Double(i)
        let a = k[max(i - 1, 0)], b = k[i], c = k[i + 1], d = k[min(i + 2, k.count - 1)]
        func curve<V: SIMD>(_ path: KeyPath<Keyframe, V>) -> V where V.Scalar == Double {
            catmullRom(a[keyPath: path], b[keyPath: path], c[keyPath: path], d[keyPath: path], t)
        }
        func scalar(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
            catmullRom(SIMD2(p0, 0), SIMD2(p1, 0), SIMD2(p2, 0), SIMD2(p3, 0), t).x
        }
        func curve(_ path: KeyPath<Keyframe, Double>) -> Double {
            scalar(a[keyPath: path], b[keyPath: path], c[keyPath: path], d[keyPath: path])
        }
        let hand: Hand = switch (a.hand, b.hand, c.hand, d.hand) {
        case let (.point(p0), .point(p1), .point(p2), .point(p3)): .point(p1.indices.map { scalar(p0[$0], p1[$0], p2[$0], p3[$0]) })
        default: b.hand
        }
        return Keyframe(pelvis: curve(\.pelvis), torso: curve(\.torso), head: curve(\.head), hand: hand, foot: curve(\.foot))
    }

    private static func catmullRom<V: SIMD>(_ p0: V, _ p1: V, _ p2: V, _ p3: V, _ t: Double) -> V where V.Scalar == Double {
        let t2 = t * t, t3 = t2 * t
        let terms = p1 * 2 + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (p1 * 3 - p0 - p2 * 3 + p3) * t3
        return terms * 0.5
    }

    private static func direction(_ degrees: Double) -> SIMD3<Double> {
        let r = degrees * .pi / 180
        return [cos(r), sin(r), 0]
    }

    // MARK: Framing

    /// The projected box the whole rep stays inside — figure, props and floor — so
    /// the camera never moves during the loop.
    nonisolated struct Framing: Sendable {
        var bounds: CGRect
        /// The floor shadow's x span.
        var floor: ClosedRange<Double>

        init(bounds: CGRect, floor: ClosedRange<Double>) {
            self.bounds = bounds
            self.floor = floor
        }

        init(of pose: ExercisePose) {
            var x0 = Double.infinity, x1 = -Double.infinity, y0 = -0.05, y1 = -Double.infinity
            var f0 = Double.infinity, f1 = -Double.infinity
            func include(_ p: SIMD3<Double>, _ r: Double) {
                let q = pose.camera.project(p)
                x0 = min(x0, q.x - r); x1 = max(x1, q.x + r); y0 = min(y0, q.y - r); y1 = max(y1, q.y + r)
            }
            for step in 0...40 {
                let s = pose.skeleton(at: Double(step) / 40)
                for side in [s.near, s.far] {
                    for joint in [side.shoulder, side.elbow, side.hip, side.knee] { include(joint, 0.08) }
                    include(side.hand, pose.props.dumbbells == true ? 0.16 : 0.08)
                    include(side.ankle, 0.19)
                    let a = pose.camera.project(side.ankle).x
                    f0 = min(f0, a - 0.12); f1 = max(f1, a + 0.18)
                }
                include(s.head, 0.13); include(s.pelvis, 0.17); include(s.shoulders, 0.17)
                if let bar = s.bar {
                    for z in [-Body.plateZ, Body.plateZ] { include([bar.x, bar.y, z], Body.plateRadius + 0.015) }
                }
            }
            if let bench = pose.props.bench {
                for x in [bench.x.x, bench.x.y] {
                    for z in [-0.2, 0.2] {
                        include([x, bench.top, z], 0.02)
                        let q = pose.camera.project([x, bench.top, z]).x
                        f0 = min(f0, q); f1 = max(f1, q)
                    }
                }
            }
            bounds = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            floor = (f0 - 0.06)...(f1 + 0.06)
        }
    }
}

nonisolated enum ExercisePoses {
    /// Loaded on first use — only screens that draw an exercise need the keyframes.
    static let all: [String: ExercisePose] = {
        guard let url = Bundle.main.url(forResource: "exercise-poses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let poses = try? JSONDecoder().decode([String: ExercisePose].self, from: data) else { return [:] }
        return poses
    }()
}
