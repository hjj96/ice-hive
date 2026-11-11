import Foundation
import Metal
import IceHiveCore

// ================================================================
//  WORLD PROPS — the interactive props on screen (Stage 1 R6 «Valves,
//  light, lockers»; the core: IceHiveCore Props.swift / GameProps.swift).
//  Geometry: built into the station mesh by WorldLevel (its cells, its one
//  pipeline: no new draw call) from runtime primitives on the station's
//  trims — no new kit piece:
//    steam valve   a steam line along its span with nozzles toward the
//                  curtain, hangers from the deck edge, the valve body, a
//                  red handwheel (turns while it vents) and a gauge (amber:
//                  ready; red flicker: bursting; white: venting; filling
//                  while it recharges); a coolant line: the same in frost
//                  blue, its gauge cold, its mist sinking ice

//    breaker       a waist-high cabinet facing the camera, a lever, a lamp
//                  on top (green: lit; red blinking: dark; amber: charging)
//    supply locker a cabinet against the rail, its door (swings open when
//                  used) and a light strip (teal: stocked; dark: used)
//  The moving / lit parts are heads of vs_kit's table (WorldLevel.setHead:
//  a pivot and a yaw for the wheel and the door, a colour for the painted
//  gauge, lamp and strip). Each station lamp's lens is a head too, and
//  every frame its light — lens, floor pool, grid light — follows the
//  core's lamp: out when broken or its circuit is off (a short dying
//  flicker), back on in a stagger rolling away from the breaker (flicker,
//  then a brief overshoot). Steam: GPU particles from the nozzles down
//  across the curtain while a valve vents, hiss puffs as it bursts. Rings:
//  breakers that need their ring and unused lockers get the telegraph
//  lexicon's gold «stand here to use it» ring (GroundGlyphs, with the
//  ring's progress). Diagnostics: `props: …` lines on every prop event and
//  `hb props …` once a second (CI's checks of the interactives demo).
//  A station without props: nothing is built, every lamp burns as built.
// ================================================================
final class WorldProps {
    /// The heads WorldProps' geometry took in WorldLevel's table (−1 none: that part stays still / as painted).
    struct Heads {
        var valveWheel: [Int] = [], valveGauge: [Int] = []
        var wheelPivot: [F3] = []
        var breakerLamp: [Int] = []
        var lockerDoor: [Int] = [], lockerLight: [Int] = []
        var doorPivot: [F3] = []
    }

    let level: Level
    private var rng = SeededRNG(seed: 4021)
    /// Lamp link (WorldLevel) → the core's lamp index (−1 none), built on the first frame with lamp states.
    private var linkLamp: [Int] = []
    private var mappedFor: ObjectIdentifier?
    private var shown: [Float] = []
    private var allOn = false
    private var wheelAngle: [Float] = []
    private var doorOpen: [Float] = []
    private var steamAcc: [Float] = []
    private var lastLog: Double = 0

    init(level: Level) { self.level = level }

    // ================================================================ geometry (WorldLevel.buildStation)
    // palette (sRGB), the station's
    private enum Col {
        static let steelD: UInt32 = 0x29313a, steel: UInt32 = 0x46515c, steelL: UInt32 = 0x6a7784, girder: UInt32 = 0x1f262e
        static let insul: UInt32 = 0x6f767d, brass: UInt32 = 0x8a6a3a, wheel: UInt32 = 0xb3312a, cabinet: UInt32 = 0x3d4652
        static let locker: UInt32 = 0x4f6b92, door: UInt32 = 0x5b7aa3, cross: UInt32 = 0xc8cdd2, lamp: UInt32 = 0xffffff
        static let frost: UInt32 = 0x8fb8d4
    }

    /// The props of `L`'s level into its station cells (nothing on a station without props).
    static func buildGeometry(_ L: WorldLevel) {
        let P = L.level.layout.props
        if P.isEmpty { return }
        var H = Heads()
        for v in P.valves { valve(L, v, &H) }
        for c in P.circuits { breaker(L, c, &H) }
        for l in P.lockers { locker(L, l, &H) }
        L.propHeads = H
    }

    /// A steam valve: the steam line through the valve parallel to its curtain (0.32 m under the valve's pipe, 0.22 m in
    /// toward the deck), nozzles every 1.5 m, hangers from the deck edge, the body, the wheel (a head), the gauge (a head).
    private static func valve(_ L: WorldLevel, _ v: ValveSite, _ H: inout Heads) {
        let level = L.level
        let dx = v.bx - v.ax, dz = v.bz - v.az, len = max(0.1, hypotf(dx, dz))
        let u = F3(dx / len, 0, dz / len)
        // the valve's offset from the curtain line → the pipe line; inward = toward the curtain
        let t0 = max(0, min(len, (v.x - v.ax) * u.x + (v.z - v.az) * u.z))
        let foot = F3(v.ax + u.x * t0, 0, v.az + u.z * t0)
        var n = F3(foot.x - v.x, 0, foot.z - v.z)
        let nl = hypotf(n.x, n.z)
        n = nl > 1e-3 ? n / nl : F3(-u.z, 0, u.x)
        let ys = v.y - 0.32
        let off = F3(v.x - foot.x, 0, v.z - foot.z) + n * 0.22
        let A = F3(v.ax, ys, v.az) + off, B = F3(v.bx, ys, v.bz) + off
        let m = L.cell(v.x, v.z)
        let cold = v.kind == .coolant
        let pipeMat = KitMat(tint: cold ? Col.frost : Col.insul, metal: 0.55, layer: Trim.pipes, flags: KitFlag.frost, uv: .strip(Trim.pipe, u))
        let brassMat = KitMat(tint: Col.brass, metal: 0.8, layer: Trim.pipes, uv: .strip(Trim.flange, u))
        let steelMat = KitMat(tint: Col.steel, metal: 0.7, layer: Trim.rails, flags: KitFlag.chamfer, uv: .strip(Trim.column, F3(0, 1, 0)))
        m.tube(A, B, r: 0.075, seg: 8, pipeMat)
        // nozzles toward the curtain, every 1.5 m
        let nn = max(1, Int((len / 1.5).rounded()))
        for k in 0...nn {
            let p = A + (B - A) * (Float(k) / Float(nn))
            m.tube(p, p + n * 0.17 + F3(0, -0.1, 0), r: 0.034, seg: 6, brassMat)
        }
        // hangers: a post from the deck edge under the line (its nearest deck point toward the curtain) with an arm
        var posts = [0, nn]
        if nn >= 4 { posts.insert(nn / 2, at: 1) }
        for k in posts {
            let p = A + (B - A) * (Float(k) / Float(nn))
            var d = F3(p.x, 0, p.z)
            var found = false
            for _ in 0..<20 where !found {
                if level.walkable(d.x, d.z) { found = true } else { d += n * 0.2 }
            }
            if !found { continue }
            let gy = level.groundY(d.x, d.z)
            if ys - gy < 0.8 { continue }
            let top = F3(d.x, ys + 0.06, d.z)
            m.tube(F3(d.x, gy, d.z), top, r: 0.05, seg: 6, steelMat)
            m.tube(top, F3(p.x, ys + 0.06, p.z), r: 0.035, seg: 6, steelMat, caps: false)
        }
        // the body (a flanged barrel across the line) and its stem
        let c = F3(v.x, ys, v.z) + n * 0.22
        m.lathe(o: c + F3(0, -0.13, 0), [(0.12, 0), (0.15, 0.04), (0.15, 0.22), (0.12, 0.26), (0.05, 0.26), (0.035, 0.44)], seg: 10,
                KitMat(tint: Col.steelL, metal: 0.75, layer: Trim.pipes, flags: KitFlag.chamfer, uv: .strip(Trim.flange, F3(0, 1, 0))))
        // the handwheel: a flat ring and three spokes (a head: it turns while the valve vents)
        let wc = c + F3(0, 0.33, 0)
        let wheelMat = KitMat(tint: cold ? 0x3a6fa8 : Col.wheel, metal: 0.35, layer: Trim.none, uv: .none)
        let w0 = m.vertices.count
        m.lathe(o: wc, [(0.14, 0), (0.21, 0), (0.21, 0.035), (0.14, 0.035), (0.14, 0)], seg: 14, wheelMat)
        for k in 0..<3 {
            let a = Float(k) * 2 * Float.pi / 3
            let r = F3(cosf(a), 0, sinf(a))
            m.beam(wc + r * 0.03 + F3(0, 0.018, 0), wc + r * 0.16 + F3(0, 0.018, 0), w: 0.03, h: 0.025, c: 0, wheelMat)
        }
        if let hk = L.allocHead() {
            m.markHead(from: w0, hk, paint: false)
            L.setHead(hk, pivot: F4(wc.x, wc.y, wc.z, 0))
            H.valveWheel.append(hk)
        } else { H.valveWheel.append(-1) }
        H.wheelPivot.append(wc)
        // the gauge on the camera's side of the body (its face a painted head: the state colour)
        let cam = F3(0.7071, 0, 0.7071)
        let gc = c + cam * 0.2 + F3(0, 0.05, 0)
        m.tube(c + cam * 0.12 + F3(0, 0.05, 0), gc, r: 0.02, seg: 6, brassMat)
        let g0 = m.vertices.count
        m.tube(gc, gc + cam * 0.035, r: 0.075, seg: 10, KitMat(tint: Col.lamp, metal: 0, emis: 2.4, layer: Trim.none, uv: .none))
        if let hk = L.allocHead() {
            m.markHead(from: g0, hk, paint: true)
            L.setHead(hk, pivot: F4(gc.x, gc.y, gc.z, 0), color: cold ? F3(0.25, 0.75, 1.2) : F3(1.0, 0.55, 0.08))
            H.valveGauge.append(hk)
        } else { H.valveGauge.append(-1) }
    }

    /// A breaker: a cabinet facing the camera on its pedestal cell, a lever, a lamp on top (a painted head).
    private static func breaker(_ L: WorldLevel, _ c: CircuitSite, _ H: inout Heads) {
        let level = L.level
        let y = level.groundY(c.x, c.z)
        let m = L.cell(c.x, c.z)
        let f = F3(0.7071, 0, 0.7071), r = F3(0.7071, 0, -0.7071)
        let o = F3(c.x, y, c.z)
        m.cbox(o: o + F3(0, 0.03, 0), ax: r, ay: F3(0, 1, 0), az: f, w: 0.62, h: 0.06, d: 0.5, c: 0.015,
               KitMat(tint: Col.steelD, metal: 0.7, layer: Trim.panels, flags: KitFlag.frost), bottom: false)
        m.cbox(o: o + F3(0, 0.62, 0), ax: r, ay: F3(0, 1, 0), az: f, w: 0.46, h: 1.12, d: 0.34, c: 0.03,
               KitMat(tint: Col.cabinet, metal: 0.5, layer: Trim.panels, flags: KitFlag.chamfer | KitFlag.frost), bottom: false)
        // a hazard band across the front, the lever
        m.cbox(o: o + F3(0, 1.0, 0) + f * 0.175, ax: r, ay: F3(0, 1, 0), az: f, w: 0.4, h: 0.07, d: 0.012, c: 0,
               KitMat(tint: 0xffa21a, metal: 0.1, layer: Trim.rails, flags: KitFlag.hazard, uv: .strip(Trim.hazard, r)), bottom: false)
        m.beam(o + F3(0, 0.62, 0) + f * 0.2 + r * 0.12, o + F3(0, 0.8, 0) + f * 0.32 + r * 0.12, w: 0.035, h: 0.035, c: 0,
               KitMat(tint: Col.steelL, metal: 0.8, layer: Trim.none, uv: .none))
        m.cbox(o: o + F3(0, 0.82, 0) + f * 0.33 + r * 0.12, w: 0.07, h: 0.07, d: 0.07, c: 0.01,
               KitMat(tint: 0xc23a2a, metal: 0.2, layer: Trim.none, uv: .none))
        // the lamp on top
        let l0 = m.vertices.count
        m.cbox(o: o + F3(0, 1.24, 0), ax: r, ay: F3(0, 1, 0), az: f, w: 0.16, h: 0.11, d: 0.16, c: 0.02,
               KitMat(tint: Col.lamp, metal: 0, emis: 3.0, layer: Trim.none, uv: .none), bottom: false)
        if let hk = L.allocHead() {
            m.markHead(from: l0, hk, paint: true)
            L.setHead(hk, pivot: F4(c.x, y + 1.24, c.z, 0), color: F3(0.2, 1.0, 0.45))
            H.breakerLamp.append(hk)
        } else { H.breakerLamp.append(-1) }
    }

    /// A supply locker: the cabinet against the rail, its door (a head: it swings open about its hinge), a pale cross on the
    /// door, a light strip over it (a painted head).
    private static func locker(_ L: WorldLevel, _ s: LockerSite, _ H: inout Heads) {
        let level = L.level
        let k = s.cabinet
        let y = level.groundY(k.x, k.y)
        let m = L.cell(k.x, k.y)
        let f = F3(sinf(s.yaw), 0, cosf(s.yaw)), ax = F3(f.z, 0, -f.x)
        let o = F3(k.x, y, k.y)
        m.cbox(o: o + F3(0, 0.95, 0), ax: ax, ay: F3(0, 1, 0), az: f, w: 0.9, h: 1.9, d: 0.55, c: 0.03,
               KitMat(tint: Col.locker, metal: 0.45, layer: Trim.panels, flags: KitFlag.chamfer | KitFlag.frost), bottom: false)
        // the door with its cross and handle: a head turning about the hinge (its −ax edge)
        let hinge = o + f * 0.295 - ax * 0.39
        let d0 = m.vertices.count
        let dc = o + F3(0, 0.98, 0) + f * 0.295
        m.cbox(o: dc, ax: ax, ay: F3(0, 1, 0), az: f, w: 0.78, h: 1.7, d: 0.04, c: 0.012,
               KitMat(tint: Col.door, metal: 0.4, layer: Trim.panels, flags: KitFlag.chamfer))
        m.cbox(o: dc + f * 0.025 + F3(0, 0.25, 0), ax: ax, ay: F3(0, 1, 0), az: f, w: 0.34, h: 0.1, d: 0.012, c: 0,
               KitMat(tint: Col.cross, metal: 0.1, layer: Trim.none, uv: .none), bottom: false)
        m.cbox(o: dc + f * 0.025 + F3(0, 0.25, 0), ax: ax, ay: F3(0, 1, 0), az: f, w: 0.1, h: 0.34, d: 0.012, c: 0,
               KitMat(tint: Col.cross, metal: 0.1, layer: Trim.none, uv: .none), bottom: false)
        m.cbox(o: dc + f * 0.03 + ax * 0.3 - F3(0, 0.05, 0), ax: ax, ay: F3(0, 1, 0), az: f, w: 0.04, h: 0.2, d: 0.03, c: 0,
               KitMat(tint: Col.steelL, metal: 0.8, layer: Trim.none, uv: .none))
        if let hk = L.allocHead() {
            m.markHead(from: d0, hk, paint: false)
            L.setHead(hk, pivot: F4(hinge.x, hinge.y, hinge.z, 0))
            H.lockerDoor.append(hk)
        } else { H.lockerDoor.append(-1) }
        H.doorPivot.append(hinge)
        // the light strip over the door
        let l0 = m.vertices.count
        m.cbox(o: o + F3(0, 1.86, 0) + f * 0.3, ax: ax, ay: F3(0, 1, 0), az: f, w: 0.6, h: 0.05, d: 0.05, c: 0,
               KitMat(tint: Col.lamp, metal: 0, emis: 3.0, layer: Trim.none, uv: .none))
        if let hk = L.allocHead() {
            m.markHead(from: l0, hk, paint: true)
            L.setHead(hk, pivot: F4(o.x, y + 1.86, o.z, 0), color: F3(0.15, 1.0, 0.85))
            H.lockerLight.append(hk)
        } else { H.lockerLight.append(-1) }
    }

    // ================================================================ per frame
    /// This frame's lamp lights, prop parts, steam and rings (MetalWorld, before the glyphs are built).
    func build(game: Game, time: Float, dt: Float, fx: MetalEffects, levelDraw L: WorldLevel, glyphs: GroundGlyphs) {
        glyphs.extra.removeAll(keepingCapacity: true)
        if level.layout.props.isEmpty { return }
        lamps(game, L)
        let H = L.propHeads
        let st = game.simTime
        let blink: Float = 0.55 + 0.45 * sinf(time * 9)
        // valves: the wheel turns while it vents, the gauge says its state
        if wheelAngle.count != game.valves.count { wheelAngle = [Float](repeating: 0, count: game.valves.count); steamAcc = wheelAngle }
        for (k, v) in game.valves.enumerated() {
            if v.phase == .venting { wheelAngle[k] += dt * 7 }
            if k < H.valveWheel.count && H.valveWheel[k] >= 0 {
                let p = H.wheelPivot[k]
                L.setHead(H.valveWheel[k], pivot: F4(p.x, p.y, p.z, wheelAngle[k]))
            }
            if k < H.valveGauge.count && H.valveGauge[k] >= 0 {
                // (steam: amber when ready; a coolant line: ice blue)
                let ready: F3 = v.site.kind == .coolant ? F3(0.25, 0.75, 1.2) : F3(1.0, 0.55, 0.08)
                let c: F3
                switch v.phase {
                case .ready: c = ready * (0.9 + 0.1 * sinf(time * 3 + Float(k)))
                case .burst: c = (v.site.kind == .coolant ? F3(1.2, 1.3, 1.4) : F3(1.3, 0.12, 0.05)) * (sinf(time * 40) > 0 ? 1 : 0.2)
                case .venting: c = v.site.kind == .coolant ? F3(0.7, 1.1, 1.4) : F3(1.2, 1.0, 0.8)
                case .recharge:
                    let g = v.gauge
                    c = (F3(0.5, 0.06, 0.02) * (1 - g) + ready * g) * (0.2 + 0.5 * g)
                }
                L.setHead(H.valveGauge[k], color: c)
            }
            steam(game, k, v, dt, fx)
        }
        // breakers: the lamp on top, the gold ring when the circuit needs it (a SWITCH step's breaker switch standing on it:
        // the switch's progress — the step's ring is the one, R1's seam)
        for (k, c) in game.circuits.enumerated() {
            var prog = c.progress
            for sw in game.switches where sw.state != 2 && sw.site.kind == .breaker
                && abs(sw.site.x - c.site.x) < 1.5 && abs(sw.site.z - c.site.z) < 1.5 { prog = sw.progress }
            let col: F3
            if prog > 0.01 { col = F3(1.2, 0.7, 0.12) * (0.6 + 0.4 * sinf(time * 14)) }
            else if c.lit { col = c.needsRestore ? F3(1.0, 0.62, 0.12) * 0.7 : F3(0.2, 1.0, 0.45) }
            else { col = F3(1.1, 0.12, 0.06) * blink }
            if k < H.breakerLamp.count && H.breakerLamp[k] >= 0 { L.setHead(H.breakerLamp[k], color: col) }
            if c.needsRestore {
                let s = c.site
                let gy = level.groundY(s.x, s.z)
                glyphs.extra.append(GlyphInstance(center: F4(s.x, gy + 0.045, s.z, s.radius), color: F4(1.0, 0.62, 0.12, 2),
                                                  a: F4(prog, 12, time * 0.2, prog > 0 ? 1 : 0.55 + 0.35 * blink), b: F4(time, 0, 0, 0)))
            }
        }
        // lockers: the light strip, the door, the ring while it is stocked
        if doorOpen.count != game.lockers.count { doorOpen = [Float](repeating: 0, count: game.lockers.count) }
        for (k, l) in game.lockers.enumerated() {
            doorOpen[k] = l.used ? min(1, doorOpen[k] + dt * 2.5) : 0
            if k < H.lockerDoor.count && H.lockerDoor[k] >= 0 {
                let p = H.doorPivot[k]
                L.setHead(H.lockerDoor[k], pivot: F4(p.x, p.y, p.z, -1.35 * smooth01f(doorOpen[k])))
            }
            let col: F3 = l.used ? F3(0.03, 0.05, 0.05) : (l.progress > 0.01 ? F3(1.2, 0.7, 0.12) * (0.6 + 0.4 * sinf(time * 14)) : F3(0.15, 1.0, 0.85))
            if k < H.lockerLight.count && H.lockerLight[k] >= 0 { L.setHead(H.lockerLight[k], color: col) }
            if !l.used {
                let s = l.site
                glyphs.extra.append(GlyphInstance(center: F4(s.x, level.groundY(s.x, s.z) + 0.045, s.z, s.radius), color: F4(1.0, 0.62, 0.12, 2),
                                                  a: F4(l.progress, 10, -time * 0.2, l.progress > 0 ? 1 : 0.5), b: F4(time, 0, 0, 0)))
            }
        }
        heartbeat(game, st)
    }

    /// Every lamp's light from the core's lamp states (all burning while the game has none: the classic mission, the title).
    private func lamps(_ game: Game, _ L: WorldLevel) {
        let links = L.lampLinks
        if game.lamps.isEmpty {
            if !allOn || shown.count != links.count {
                for n in links.indices { L.setLampLevel(n, 1) }
                shown = [Float](repeating: 1, count: links.count)
                allOn = true
            }
            return
        }
        allOn = false
        if mappedFor != ObjectIdentifier(game) || linkLamp.count != links.count {
            mappedFor = ObjectIdentifier(game)
            linkLamp = links.map { lk in game.lamps.firstIndex { abs($0.site.x - lk.x) < 0.06 && abs($0.site.z - lk.z) < 0.06 } ?? -1 }
            shown = [Float](repeating: -1, count: links.count)
        }
        let t = game.simTime
        for n in links.indices {
            let k = linkLamp[n]
            var lv: Float = 1
            if k >= 0 {
                let s = game.lamps[k]
                let age = t - s.changedAt
                let seed = Float(k) * 7.31
                if s.on {
                    // a restore rolls away from the breaker: 0.07 s per metre, then a 0.5 s flicker, then a short overshoot
                    var delay: Float = 0
                    let c = s.site.circuit
                    if c >= 0 && c < game.circuits.count && abs(game.circuits[c].restoredAt - s.changedAt) < 0.02 {
                        let b = game.circuits[c].site
                        delay = min(1.4, hypotf(s.site.x - b.x, s.site.z - b.z) * 0.07)
                    }
                    let a = age - delay
                    if a < 0 { lv = 0 }
                    else if a < 0.5 { lv = WorldProps.hash(floorf(a * 22) + seed) > 0.42 ? 0.3 + 1.2 * a : 0.04 }
                    else { lv = 1 + 0.6 * expf(-(a - 0.5) * 5) }
                } else {
                    // a dying flicker, then dark
                    lv = age < 0.28 ? (WorldProps.hash(floorf(age * 30) + seed) > 0.5 ? 1 - age * 2.5 : 0.05) : 0
                }
            }
            if abs(lv - shown[n]) > 0.004 {
                shown[n] = lv
                L.setLampLevel(n, lv)
            }
        }
    }

    /// Steam: the burst's hiss puffs at the valve; while it vents, jets from the nozzles across to the curtain and a billowing
    /// sheet over its strip on the deck.
    private func steam(_ game: Game, _ k: Int, _ v: ValveState, _ dt: Float, _ fx: MetalEffects) {
        let s = v.site
        guard v.phase == .burst || v.phase == .venting, dt > 0 else { steamAcc[k] = 0; return }
        let dx = s.bx - s.ax, dz = s.bz - s.az, len = max(0.1, hypotf(dx, dz))
        let u = F3(dx / len, 0, dz / len)
        let t0 = max(0, min(len, (s.x - s.ax) * u.x + (s.z - s.az) * u.z))
        let foot = F3(s.ax + u.x * t0, 0, s.az + u.z * t0)
        var n = F3(foot.x - s.x, 0, foot.z - s.z)
        let nl = hypotf(n.x, n.z)
        n = nl > 1e-3 ? n / nl : F3(-u.z, 0, u.x)
        let ys = s.y - 0.32
        let off = F3(s.x - foot.x, 0, s.z - foot.z) + n * 0.22
        let deckY = level.groundY(s.mid.x, s.mid.y)
        let k2 = max(0.4, fx.fxK)
        if s.kind == .coolant { mist(k, s, v, dt, fx, ys: ys, off: off, n: n, nl: nl, deckY: deckY, k2: k2); return }
        if v.phase == .burst {
            steamAcc[k] += dt * 40 * k2
            while steamAcc[k] >= 1 {
                steamAcc[k] -= 1
                let c = F3(s.x, ys + 0.1, s.z) + n * 0.22
                fx.gpu.burst(.steam, 2, at: c, jitter: F3(0.08, 0.05, 0.08), vel: F3(0, 1.4, 0) + n * 1.2, velJitter: F3(1.2, 0.8, 1.2),
                             life: (0.35, 0.6), size: (0.12, 0.6), color: F4(0.8, 0.85, 0.9, 0.4), gravity: -0.6, drag: 2.2, spin: 0.8)
            }
            return
        }
        steamAcc[k] += dt * 34 * k2
        while steamAcc[k] >= 1 {
            steamAcc[k] -= 1
            let a = rng.next()
            // a jet from a nozzle across to the curtain, down
            let p = F3(s.ax + dx * a, ys - 0.08, s.az + dz * a) + off + n * 0.18
            let drop = max(1.0, ys - deckY)
            fx.gpu.burst(.steam, 2, at: p, jitter: F3(0.12, 0.06, 0.12), vel: n * (0.9 + nl * 0.55) + F3(0, -drop * 1.1, 0),
                         velJitter: F3(0.5, 0.6, 0.5), life: (0.6, 1.0), size: (0.22, 1.25), color: F4(0.82, 0.88, 0.94, 0.3),
                         gravity: -0.4, drag: 1.4, spin: 0.6)
            // the sheet over the strip: low billows
            let b = rng.next(), w = (rng.next() * 2 - 1) * s.width * 0.8
            let q = F3(s.ax + dx * b, deckY + 0.25 + rng.next() * 1.4, s.az + dz * b) + n * w
            fx.gpu.burst(.steam, 1, at: q, jitter: F3(0.2, 0.15, 0.2), vel: F3(0, 0.25, 0), velJitter: F3(0.35, 0.3, 0.35),
                         life: (0.8, 1.4), size: (0.5, 1.7), color: F4(0.78, 0.84, 0.9, 0.2), gravity: -0.7, drag: 1.1, spin: 0.4)
        }
    }

    /// A coolant line: frost-blue puffs as it bursts; then a freezing mist pouring from the nozzles and sinking over its strip
    /// (ice glints in it).
    private func mist(_ k: Int, _ s: ValveSite, _ v: ValveState, _ dt: Float, _ fx: MetalEffects, ys: Float, off: F3, n: F3, nl: Float,
                      deckY: Float, k2: Float) {
        let dx = s.bx - s.ax, dz = s.bz - s.az
        if v.phase == .burst {
            steamAcc[k] += dt * 40 * k2
            while steamAcc[k] >= 1 {
                steamAcc[k] -= 1
                let c = F3(s.x, ys + 0.1, s.z) + n * 0.22
                fx.gpu.burst(.steam, 2, at: c, jitter: F3(0.08, 0.05, 0.08), vel: F3(0, 0.8, 0) + n * 1.2, velJitter: F3(1.0, 0.6, 1.0),
                             life: (0.35, 0.6), size: (0.12, 0.55), color: F4(0.6, 0.8, 1.0, 0.45), gravity: 0.4, drag: 2.2, spin: 0.8)
            }
            return
        }
        steamAcc[k] += dt * 30 * k2
        while steamAcc[k] >= 1 {
            steamAcc[k] -= 1
            let a = rng.next()
            let p = F3(s.ax + dx * a, ys - 0.08, s.az + dz * a) + off + n * 0.18
            let drop = max(1.0, ys - deckY)
            fx.gpu.burst(.steam, 2, at: p, jitter: F3(0.12, 0.06, 0.12), vel: n * (0.7 + nl * 0.5) + F3(0, -drop * 0.9, 0),
                         velJitter: F3(0.4, 0.5, 0.4), life: (0.7, 1.1), size: (0.2, 1.1), color: F4(0.62, 0.8, 1.0, 0.32),
                         gravity: 0.8, drag: 1.4, spin: 0.5)
            let b = rng.next(), w = (rng.next() * 2 - 1) * s.width * 0.8
            let q = F3(s.ax + dx * b, deckY + 0.15 + rng.next() * 0.6, s.az + dz * b) + n * w
            fx.gpu.burst(.steam, 1, at: q, jitter: F3(0.25, 0.1, 0.25), vel: F3(0, -0.1, 0), velJitter: F3(0.4, 0.1, 0.4),
                         life: (1.0, 1.6), size: (0.6, 1.8), color: F4(0.55, 0.75, 0.95, 0.24), gravity: 0.3, drag: 1.2, spin: 0.3)
            fx.gpu.burst(.ice, 1, at: q + F3(0, 0.6, 0), jitter: F3(0.3, 0.3, 0.3), vel: F3(0, -0.4, 0), velJitter: F3(0.3, 0.3, 0.3),
                         life: (0.5, 0.9), size: (0.04, 0.02), color: F4(0.7, 1.0, 1.3, 1), gravity: 1, drag: 1)
        }
    }

    // ================================================================ events
    func handle(_ e: GameEvent, game: Game, fx: MetalEffects) {
        let diag = AppLog.diagnostics
        switch e {
        case .valveHit(let k):
            guard k >= 0 && k < game.valves.count else { return }
            let s = game.valves[k].site
            fx.gpu.burst(.spark, 4, at: F3(s.x, s.y - 0.2, s.z), vel: F3(0, 1.0, 0), velJitter: F3(2.2, 1.6, 2.2), life: (0.12, 0.3),
                         size: (0.03, 0.02), color: F4(1.3, 1.0, 0.6, 1), gravity: 9, drag: 1.5)
        case .valveBurst(let k):
            guard k >= 0 && k < game.valves.count else { return }
            let s = game.valves[k].site
            fx.flash(F3(s.x, s.y - 0.3, s.z), F3(1.0, 0.55, 0.15), peak: 40, dur: 0.3, range: 6, priority: 18)
            if diag { AppLog.info(String(format: "props: valve %d burst by %d at t=%.2f", k, game.valves[k].src, game.time)) }
        case .valveVented(let k):
            guard k >= 0 && k < game.valves.count else { return }
            if diag {
                AppLog.info(String(format: "props: valve %d %@ up, %d bugs under it", k, game.valves[k].site.kind == .coolant ? "(coolant) mist" : "curtain",
                                   game.valves[k].crowd))
            }
        case .valveReady(let k):
            if diag { AppLog.info("props: valve \(k) ready") }
        case .lampBroken(let k):
            guard k >= 0 && k < game.lamps.count else { return }
            let l = game.lamps[k].site.lens
            let p = F3(l.x, l.y, l.z)
            fx.gpu.burst(.spark, 10, at: p, vel: F3(0, -0.5, 0), velJitter: F3(2.4, 1.8, 2.4), life: (0.2, 0.5), size: (0.035, 0.02),
                         color: F4(1.1, 1.3, 1.2, 1), gravity: 9, drag: 1.2)
            fx.gpu.burst(.ice, 6, at: p, vel: F3(0, -1, 0), velJitter: F3(1.4, 0.6, 1.4), life: (0.5, 0.8), size: (0.05, 0.03),
                         color: F4(0.5, 0.9, 0.9, 1), gravity: 11, drag: 0.4, bounce: 0.3)
            fx.flash(p, F3(0.3, 1.0, 0.9), peak: 30, dur: 0.15, range: 5, priority: 12)
            if diag { AppLog.info(String(format: "props: lamp %d broken (circuit %d) t=%.2f", k, game.lamps[k].site.circuit, game.time)) }
        case .circuitRestored(let k):
            guard k >= 0 && k < game.circuits.count else { return }
            let s = game.circuits[k].site
            let p = F3(s.x, level.groundY(s.x, s.z) + 1.3, s.z)
            fx.gpu.burst(.spark, 12, at: p, vel: F3(0, 1.6, 0), velJitter: F3(1.6, 1.4, 1.6), life: (0.2, 0.45), size: (0.03, 0.02),
                         color: F4(0.8, 1.4, 1.0, 1), gravity: 8, drag: 1.2)
            fx.flash(p, F3(0.3, 1.0, 0.55), peak: 60, dur: 0.35, range: 7, priority: 16)
            if diag {
                AppLog.info(String(format: "props: circuit %d restored, lamps %d/%d, lit circuits %d/%d t=%.2f", k, game.circuits[k].burning,
                                   game.circuits[k].lamps.count, game.lightsLit, game.circuits.count, game.time))
            }
        case .circuitCut(let k):
            if diag { AppLog.info(String(format: "props: circuit %d cut t=%.2f", k, game.time)) }
        case .lockerOpened(let k, let who):
            guard k >= 0 && k < game.lockers.count else { return }
            let s = game.lockers[k].site
            let c = s.cabinet
            fx.flash(F3(c.x, level.groundY(c.x, c.y) + 1.6, c.y), F3(0.2, 1.0, 0.85), peak: 40, dur: 0.4, range: 5, priority: 12)
            if diag { AppLog.info("props: locker \(k) opened by \(who)") }
        default:
            break
        }
    }

    /// Once a second (diagnostics): `hb props lit=… lamps=… valves=… (r ready, w warning, v venting, c recharging) …`.
    private func heartbeat(_ game: Game, _ t: Float) {
        guard AppLog.diagnostics, !game.attract else { return }
        let now = FrameTimer.now()
        if now - lastLog < 1 { return }
        lastLog = now
        let on = game.lamps.filter { $0.on }.count
        let vs = game.valves.map { v -> String in
            switch v.phase { case .ready: return "r"; case .burst: return "w"; case .venting: return "v"; case .recharge: return "c" }
        }.joined()
        let st = game.propStats
        AppLog.info("hb props lit=\(game.lightsLit)/\(game.circuits.count) lamps=\(on)/\(game.lamps.count) valves=\(vs)"
                    + " bursts=\(st.bursts) kills=\(st.curtainKills)+\(st.upKills) broken=\(st.lampsBroken) spits=\(st.lampSpits)"
                    + " restores=\(st.restores) lockers=\(st.lockers)")
    }

    /// A stable pseudo-random 0…1 of `x` (the lamps' flicker; no state).
    @inline(__always) static func hash(_ x: Float) -> Float {
        let s = sinf(x * 12.9898 + 78.233) * 43758.5453
        return s - floorf(s)
    }
}
