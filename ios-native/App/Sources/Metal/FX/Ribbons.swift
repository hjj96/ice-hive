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
    static let tracerLength: [Float] = [2.4, 1.7, 1.6]
    /// Tracer HDR colours: the class hue (assault red, gunner green; the turret a paler green-teal).
    static let tracerColor: [F3] = [F3(3.4, 0.42, 0.26), F3(0.55, 3.1, 0.75), F3(0.5, 2.6, 1.5)]

    private(set) var beams: [BeamInstance] = []
    private var renderer: MetalRenderer?
    private var ps: MTLRenderPipelineState?
    private var region = Region()
    /// Longest tracer drawn since the last heartbeat (m; acceptance ≤ 3 m).
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
            let y = 1.2 + level.groundY(p.x, p.y)
            let head = F3(p.x, y, p.y), tail = F3(p.x - d.x * len, y, p.y - d.y * len)
            let c = Ribbons.tracerColor[ci]
            add(tail, head, width: ci == 0 ? 0.07 : 0.058, mode: .tracer, color: c, head: ci == 0 ? 8 : 6.5)
            add(tail, head, width: ci == 0 ? 0.26 : 0.21, mode: .halo, color: c * 0.32)
            longestTracer = max(longestTracer, len)
            tracersDrawn += 1
        }
    }

    /// Short glint ribbon from a to b, half width `w`: brightest at the start, k² to nothing at the end.
    func glint(_ a: F3, _ b: F3, width w: Float, color: F3, intensity: Float) {
        add(a, b, width: w, mode: .glint, color: color, intensity: intensity)
    }

    /// The cryo beam from `from` along the aim (unit xz) over `len`: 8 segments sagging toward the deck and wobbling.
    func cryoBeam(from o: F3, ax: Float, az: Float, len: Float, time: Float, seed: Float) {
        let n = 8
        func pt(_ u: Float) -> F3 {
            let along = u * len
            let wob = sinf(time * 13 + u * 9 + seed) * 0.05 * u
            return F3(o.x + ax * along + az * wob, o.y - u * u * 0.55, o.z + az * along - ax * wob)
        }
        let flick = 0.88 + 0.12 * sinf(time * 41 + seed)
        for s in 0..<n {
            let u0 = Float(s) / Float(n), u1 = Float(s + 1) / Float(n)
            // the sheath widens with the distance from the emitter (m), not with the fraction of a short beam
            let w = min(0.42, 0.13 + 0.045 * (u0 + u1) * 0.5 * len)
            add(pt(u0), pt(u1), width: w, mode: .cryo, color: F3(1, 1, 1), intensity: flick, u0: u0, u1: u1, seed: seed)
        }
        // a wide cold halo along the whole beam
        add(pt(0), pt(1), width: min(0.9, 0.35 + 0.06 * len), mode: .halo, color: F3(0.1, 0.3, 0.75), intensity: 0.55)
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
