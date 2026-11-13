import IceHiveCore

// ================================================================
//  TOAST THING (Stage 2 H1) — what a toast names in the world, now: a
//  tip waits for its thing (ToastQueue), a threat lasts while its
//  marine is still pinned / down, and the toast column keeps clear of
//  the thing on screen (HUD: the column's side). Read-only, from the
//  game's public state; pure (no SpriteKit).
// ================================================================
enum ToastThing: Equatable {
    /// It names nothing in the world (a bark): always shown.
    case none
    /// Its thing is not there now (the rattle is over, the spitter left its perch, the valve is spent, …).
    case gone
    /// Where it is: x, ABSOLUTE y, z (world).
    case at(SIMD3<Float>)

    var fresh: Bool { self != .gone }

    /// Reach of a prop tip: 1.5 × the core's own first-sighting reach (valve 12 m, breaker / locker 9 m) — the squad
    /// keeps moving while a tip waits its turn.
    static let valveReach: Float = 18, propReach: Float = 14
    /// A bug-kind tip («Spitter: acid spit …») holds while one of its kind is alive this close.
    static let bugReach: Float = 45
    /// «Duct rattling — shoot it shut» needs a rattle with this much left (of DUCT_RATTLE's 2 s) to be acted on.
    static let rattleLeft: Float = 0.8

    static func of(_ t: GameText, _ g: Game) -> ToastThing {
        let P = g.player
        func d2(_ x: Float, _ z: Float) -> Float { (x - P.x) * (x - P.x) + (z - P.z) * (z - P.z) }
        func ground(_ x: Float, _ z: Float) -> SIMD3<Float> { SIMD3(x, g.level.groundY(x, z), z) }
        func marine(_ n: NameRef?) -> Marine? { g.marines.first { $0.name == n } }
        func named() -> NameRef? {
            for a in t.args { if case .name(let n) = a { return n } }
            return nil
        }
        /// The nearest live bug of `type` (optionally in `state`) within `reach`.
        func bug(_ type: BugType, state: BugState? = nil, reach: Float = .infinity) -> SIMD3<Float>? {
            let S = g.bugs
            var best: Float = reach * reach, at: SIMD3<Float>? = nil
            var i = 0
            while i < S.count {
                if !S.isDead(i) && S.bugType(i) == type && !S.isBoss(i) && (state == nil || S.state(i) == state) {
                    let p = S.position(i)
                    let d = d2(p.x, p.y)
                    if d < best {
                        best = d
                        let h = S.heights[i]
                        at = SIMD3(p.x, S.hasAbsoluteHeight(i) ? h : g.level.groundY(p.x, p.y) + h, p.y)
                    }
                }
                i += 1
            }
            return at
        }
        switch t.id {
        // ---- threats: while the marine is still in trouble
        case .toastMatePinned:
            guard let m = marine(named()), m.pinned else { return .gone }
            return .at(ground(m.x, m.z))
        case .toastMateDown:
            guard let m = marine(named()), m.downed else { return .gone }
            return .at(ground(m.x, m.z))
        case .toastPlayerDown:
            return P.downed ? .at(ground(P.x, P.z)) : .gone
        // ---- Stage 2 B5, the Threader's traps (H1's handoff): while its coil is closing, while its light is lit
        case .toastThreaderCoil:
            guard g.boss.alive && g.boss.kind == .threader else { return .gone }
            let v = g.threader
            return v.coil && v.coilT >= 0 ? .at(ground(v.coilCenter.x, v.coilCenter.y)) : .gone
        case .toastThreaderLight:
            guard g.boss.alive && g.boss.kind == .threader else { return .gone }
            let v = g.threader
            return v.lure ? .at(ground(v.lureSpot.x, v.lureSpot.y)) : .gone
        // ---- first sightings: while their thing is there
        case .toastTipDuct:
            var best = Float.infinity, at: SIMD3<Float>? = nil
            for d in g.ducts where d.rattleT >= rattleLeft && d2(d.pos.x, d.pos.z) < best { best = d2(d.pos.x, d.pos.z); at = d.pos }
            return at.map { .at($0) } ?? .gone
        case .toastTipPerch:
            return bug(.spitter, state: .perch).map { .at($0) } ?? .gone
        case .toastTipDropper:
            if let b = bug(.dropper) { return .at(b) }
            for z in g.dropZones where z.active { return .at(ground(z.x, z.z)) }
            return .gone
        case .toastTipSpitter: return bug(.spitter, reach: bugReach).map { .at($0) } ?? .gone
        case .toastTipBrute: return bug(.brute, reach: bugReach).map { .at($0) } ?? .gone
        case .toastTipBoomer: return bug(.boomer, reach: bugReach).map { .at($0) } ?? .gone
        case .toastTipValve:
            var best = valveReach * valveReach, at: SIMD3<Float>? = nil
            for v in g.valves where v.phase == .ready && d2(v.site.x, v.site.z) < best {
                best = d2(v.site.x, v.site.z); at = SIMD3(v.site.x, v.site.y, v.site.z)
            }
            return at.map { .at($0) } ?? .gone
        case .toastTipBreaker:
            var best = propReach * propReach, at: SIMD3<Float>? = nil
            for c in g.circuits where c.needsRestore && d2(c.site.x, c.site.z) < best {
                best = d2(c.site.x, c.site.z); at = ground(c.site.x, c.site.z)
            }
            return at.map { .at($0) } ?? .gone
        case .toastTipLocker:
            var best = propReach * propReach, at: SIMD3<Float>? = nil
            for l in g.lockers where !l.used && d2(l.site.x, l.site.z) < best {
                best = d2(l.site.x, l.site.z); at = ground(l.site.x, l.site.z)
            }
            return at.map { .at($0) } ?? .gone
        default:
            return .none
        }
    }
}
