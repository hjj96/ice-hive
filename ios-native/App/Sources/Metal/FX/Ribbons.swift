import Foundation
import Metal
import IceHiveCore

// ================================================================
//  RIBBONS — camera-facing beams of the effects (owned by WP5
//  «Эффекты»; FX.metal vs_beam / fs_beam), one instanced additive draw
//  (transparent item 600, 6 vertices per beam):
//    tracers   every projectile in flight as a SHORT HDR bolt (≤ 3 m:
//              the rifle 2.4 m, the rotary 1.7 m, the turret 1.6 m) in
//              its class colour with a white-hot head and a faint wide
//              halo — no ribbon from the muzzle to the target;
//    glints    the short sight glints off firing muzzles (LAND: no
//              constant laser lines);
//    cryo      the cryo beam: a white-cyan core, a crackling sheath and
//              swirling frost, in segments that wobble a little;
//    columns   the beacon light columns.
// ================================================================

/// One beam (`struct BeamInstance` in FX.metal), 64 bytes.
struct BeamInstance {
    /// xyz start, w = half width (m).
    var a: F4
    /// xyz end, w = mode (Ribbons.Mode).
    var b: F4
    /// rgb HDR colour, w = intensity.
    var color: F4
    /// x u at a, y u at b (along a longer beam), z seed, w tracer head intensity.
    var params: F4
}

final class Ribbons {
    enum Mode: Float { case tracer = 0, glint = 1, cryo = 2, column = 3, halo = 4 }

    static let pipelines: [PipelineSpec] = [.world("beams", "vs_beam", "fs_beam", .add)]
    /// Tracer length (m) by projectile colour index (0 rifle, 1 rotary, 2 turret) — the plan's ≤ 3 m.
    /// native-vx-feel (subtler tracers): shorter streaks (2.8 / 2.2 / 1.8 → 1.8 / 1.4 / 1.2 m), a dimmer body and head, a
    /// narrower halo; the squad's bots draw theirs at 55 % with no halo — the player's own fire stays the brightest.
    static let tracerLength: [Float] = [1.8, 1.4, 1.2]
    /// Tracer HDR colours: the class hue (assault red, gunner green; the turret a paler green-teal).
    static let tracerColor: [F3] = [F3(3.2, 0.48, 0.26), F3(0.52, 2.8, 0.7), F3(0.45, 2.3, 1.3)]

    private(set) var beams: [BeamInstance] = []
    private var renderer: MetalRenderer?
    private var ps: MTLRenderPipelineState?
    private var region = Region()
    /// Longest tracer drawn since the last heartbeat (m; acceptance ≤ 3 m).
    /// Tracer thickness at this frame's camera (MetalEffects sets it from WorldSquad.gameK): 1 in the close-ups, 1.6 at
    /// the game camera, where a 10 cm bolt was ≈ 2 px of core on a phone (native-vx-squad: «эффекты стрельбы эпичнее»).
    var tracerScale: Float = 1
    private(set) var longestTracer: Float = 0
    private(set) var tracersDrawn = 0

    init() {
        beams.reserveCapacity(1024)
        assert(MemoryLayout<BeamInstance>.stride == 64, "BeamInstance is 64 bytes in FX.metal")
    }

    func attach(_ r: MetalRenderer) {
        renderer = r
        ps = r.pipeline("beams")
        r.register(.transparent, order: 600, "beams") { [unowned self] enc in self.encode(enc) }
    }

    func begin() { beams.removeAll(keepingCapacity: true) }

    @inline(__always) func add(_ a: F3, _ b: F3, width: Float, mode: Mode, color: F3, intensity: Float = 1,
                               u0: Float = 0, u1: Float = 1, seed: Float = 0, head: Float = 0) {
        beams.append(BeamInstance(a: F4(a.x, a.y, a.z, width), b: F4(b.x, b.y, b.z, mode.rawValue),
                                  color: F4(color.x, color.y, color.z, intensity), params: F4(u0, u1, seed, head)))
    }

    /// Every projectile in flight: a short bolt behind its head (the head where the core has it now), a wide halo.
    func tracers(game: Game, level: Level) {
        let P = game.projectiles
        for k in 0..<P.count {
            let p = P.position(k), d = P.direction(k)
            let ci = max(0, min(2, P.colorIndex(k)))
            let len = min(Ribbons.tracerLength[ci], P.speed(k) * 0.034)
            var y = 1.2 + level.groundY(p.x, p.y)
            var dir = d3(d)
            if P.aimedUp(k) {
                // Stage 1 R3: a round fired at a bug up on the overhead climbs toward it (the core keeps it 2-D: it strikes
                // the bug's footprint) — the bolt tilts up from the shooter's muzzle height to the route's ≈ 4.5 m
                let o = P.owner(k)
                let from: Vec2? = o >= 0 && o < game.marines.count ? Vec2(game.marines[o].x, game.marines[o].z)
                    : (game.turret.active ? Vec2(game.turret.x, game.turret.z) : nil)
                if let f = from {
                    let run = ((p.x - f.x) * (p.x - f.x) + (p.y - f.y) * (p.y - f.y)).squareRoot()
                    let rise = min(3.3, run * Ribbons.aimUpSlope)
                    y += rise
                    if rise < 3.3 { dir = F3(d.x, Ribbons.aimUpSlope, d.y) / (1 + Ribbons.aimUpSlope * Ribbons.aimUpSlope).squareRoot() }
                }
            }
            bolt(head: F3(p.x, y, p.y), dir: dir, len: len, ci: ci, bot: P.owner(k) != 0)
        }
    }

    /// The climb of a tracer aimed at the overhead (m up per m run: ≈ 3.3 m over the 6–8 m to a rack).
    static let aimUpSlope: Float = 0.5

    /// One tracer bolt: `len` m behind its head along the unit `dir`, in projectile colour `ci` (Ribbons.tracerColor).
    func bolt(head: F3, dir: F3, len: Float, ci: Int, bot: Bool = false) {
        let tail = head - dir * len
        let c = Ribbons.tracerColor[max(0, min(2, ci))] * (bot ? 0.55 : 1)
        // polish (owner: «эффекты стрельбы эпичнее»): a thinner, hotter bolt — a crisp white-hot head and a glow
        // around the head only; a halo along the whole bolt read as a glowing rod (a light sabre) in CI combat
        let k = tracerScale
        add(tail, head, width: (ci == 0 ? 0.04 : 0.036) * k, mode: .tracer, color: c, head: (ci == 0 ? 8 : 6) * (bot ? 0.6 : 1))
        if !bot {
            let hs = tail + (head - tail) * 0.6
            // the halo by the camera too: 0.3 m wide in a close-up it read as a glowing bar (burst fire f62cf27)
            let gk = max(0, min(1, (k - 1) / 0.6))
            add(hs, head + dir * 0.1, width: (ci == 0 ? 0.2 : 0.17) * (0.4 + 0.6 * gk), mode: .halo, color: c * (0.16 + 0.1 * gk))
        }
        longestTracer = max(longestTracer, len)
        tracersDrawn += 1
    }

    @inline(__always) private func d3(_ d: Vec2) -> F3 { F3(d.x, 0, d.y) }

    /// Short glint ribbon from a to b, half width `w`: brightest at the start, k² to nothing at the end.
    func glint(_ a: F3, _ b: F3, width w: Float, color: F3, intensity: Float) {
        add(a, b, width: w, mode: .glint, color: color, intensity: intensity)
    }

    /// The cryo beam from `from` along the aim (unit xz) over `len`: 8 segments sagging toward the deck and wobbling.
    /// `soft` 0…1: a frost stream rather than a bright line (the game camera: a dimmer core, a stronger frost sheath).
    /// `coreEnd`: the fraction of the length after which the white core is gone (FX.metal BM_CRYO: softness 2), the sheath
    /// and crackle going on — the core stops at the first bug it meets at the game camera.
    func cryoBeam(from o: F3, ax: Float, az: Float, len: Float, time: Float, seed: Float, intensity: Float = 1, widthK: Float = 1,
                  soft: Float = 0, coreEnd: Float = 1) {
        let n = 8
        func pt(_ u: Float) -> F3 {
            let along = u * len
            let wob = sinf(time * 13 + u * 9 + seed) * 0.05 * u
            return F3(o.x + ax * along + az * wob, o.y - u * u * 0.55, o.z + az * along - ax * wob)
        }
        let flick = (0.88 + 0.12 * sinf(time * 41 + seed)) * intensity
        for s in 0..<n {
            let u0 = Float(s) / Float(n), u1 = Float(s + 1) / Float(n)
            // the sheath widens with the distance from the emitter (m), not with the fraction of a short beam
            let w = min(0.42, 0.13 + 0.045 * (u0 + u1) * 0.5 * len) * widthK
            let cut = coreEnd < 1 ? smooth01f(((u0 + u1) * 0.5 - coreEnd) / 0.12 + 0.3) : 0
            add(pt(u0), pt(u1), width: w, mode: .cryo, color: F3(1, 1, 1), intensity: flick, u0: u0, u1: u1, seed: seed,
                head: soft + (2 - soft) * cut)
        }
        // a wide cold halo along the whole beam (native-vx-feel: 0.55 → 0.32)
        add(pt(0), pt(1), width: min(0.9, 0.35 + 0.06 * len) * widthK, mode: .halo, color: F3(0.1, 0.3, 0.75), intensity: 0.32 * intensity)
    }

    /// A light column (beacons): camera-facing, fading upward.
    func column(base: F3, height: Float, width: Float, color: F3, intensity: Float) {
        add(base, base + F3(0, height, 0), width: width, mode: .column, color: color, intensity: intensity)
    }

    func upload(_ r: MetalRenderer) { region = r.upload(beams) }

    func takeTracerStats() -> (longest: Float, drawn: Int) {
        defer { longestTracer = 0; tracersDrawn = 0 }
        return (longestTracer, tracersDrawn)
    }

    private func encode(_ enc: MTLRenderCommandEncoder) {
        guard let r = renderer, let ps = ps, region.count > 0 else { return }
        r.use(enc, ps)
        enc.setVertexBuffer(r.arena, offset: region.offset, index: BufferIndex.instances)
        r.drawQuads(enc, region.count)
    }
}
