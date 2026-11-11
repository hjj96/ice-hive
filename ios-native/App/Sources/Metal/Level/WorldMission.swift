import Foundation
import IceHiveCore

// ================================================================
//  WORLD MISSION — the mission plan on screen (Stage 1 R7 «Missions I»;
//  the core: Mission.swift / GameMission.swift / MissionsKelvin.swift).
//  What the deck says about the plan's objectives beyond the classic
//  beacons and lift (R1's open seam «draw the switch rings and the deck
//  hold zone»):
//    switch rings  every switch of the current SWITCH step not thrown yet
//                  gets the telegraph lexicon's gold «stand here» ring
//                  with its progress (blinking while it waits, steady
//                  while it is thrown); a breaker switch standing on a
//                  light circuit's breaker is WorldProps' ring (R6)
//    a deck zone   a HOLD or BOSS step on a deck: its circle in teal like
//                  the lift's, the hold's countdown filling round it
//    vents         a vent a seal shut goes dark — its grille glow and grid
//                  light out after a short dying flicker; a vent pouring a
//                  pack flares hot for a moment, with a puff of frost
//  (beacons the plan does not charge stand dormant: GroundGlyphs skips
//  their rings, WorldLevel darkens their lamps.) Diagnostics: `hb mission
//  …` once a second in a mission with a plan of its own.
//  Nothing is drawn or touched in the classic mission or on the title.
// ================================================================
final class WorldMission {
    let level: Level
    /// Each vent's light now (1 as built) and its pour flare (s left), the sim time it was shut (−1 open).
    private var ventShown: [Float] = []
    private var ventFlare: [Float] = []
    private var ventShutAt: [Float] = []
    private var lastLog: Double = 0

    init(level: Level) { self.level = level }

    /// This frame's rings into `glyphs.extra` (after WorldProps cleared and filled it) and the vents' light.
    func build(game: Game, time: Float, dt: Float, levelDraw L: WorldLevel, glyphs: GroundGlyphs) {
        if game.attract { return }
        // switch rings (a breaker switch on a light circuit's breaker: WorldProps draws that one, with this progress)
        let blink: Float = 0.55 + 0.35 * sinf(time * 9)
        for sw in game.switches where sw.state != 2 {
            let s = sw.site
            if s.kind == .breaker && game.circuits.contains(where: { abs($0.site.x - s.x) < 1.5 && abs($0.site.z - s.z) < 1.5 }) { continue }
            let gy = level.groundY(s.x, s.z)
            glyphs.extra.append(GlyphInstance(center: F4(s.x, gy + 0.045, s.z, s.radius), color: F4(1.0, 0.62, 0.12, 2),
                                              a: F4(sw.progress, 12, time * 0.2, sw.state == 1 ? 1 : blink), b: F4(time, 0, 0, 0)))
        }
        // a hold or a boss fight on a deck: its zone, the countdown round it
        if case .circle(let x, let z, let r)? = game.missionZone {
            let prog: Float = game.holdActive && game.liftDur.isFinite && game.liftDur > 0 ? 1 - game.liftT / game.liftDur : 0
            glyphs.extra.append(GlyphInstance(center: F4(x, level.groundY(x, z) + 0.06, z, r), color: F4(0.2, 1.0, 0.82, 2),
                                              a: F4(prog, 32, -time * 0.1, game.holdActive ? 0.7 : 0.45 + 0.25 * blink), b: F4(time, 0, 0, 0)))
        }
        vents(game, L, time, dt)
        heartbeat(game)
    }

    /// The vents' light: shut — out after a 0.5 s dying flicker; pouring — a hot flare decaying over 1.2 s.
    private func vents(_ game: Game, _ L: WorldLevel, _ time: Float, _ dt: Float) {
        let n = min(L.ventLinks.count, game.ventShut.count)
        if ventShown.count != n {
            ventShown = [Float](repeating: 1, count: n); ventFlare = ventShown.map { _ in 0 }; ventShutAt = ventShown.map { _ in -1 }
        }
        let st = game.simTime
        for k in 0..<n {
            if ventFlare[k] > 0 { ventFlare[k] = max(0, ventFlare[k] - dt) }
            var lv: Float = 1
            if game.ventShut[k] {
                if ventShutAt[k] < 0 { ventShutAt[k] = st }
                let u = st - ventShutAt[k]
                lv = u < 0.5 ? (WorldProps.hash(Float(Int(u * 30)) + Float(k)) > 0.45 ? 0.8 : 0.08) * (1 - u / 0.5) : 0
            } else if ventFlare[k] > 0 {
                lv = 1 + 1.8 * ventFlare[k] / 1.2
            }
            if lv != ventShown[k] { ventShown[k] = lv; L.setVentLevel(k, lv) }
        }
    }

    // ================================================================ events
    func handle(_ e: GameEvent, game: Game, fx: MetalEffects) {
        switch e {
        case .ventPour(let k, _):
            guard k >= 0 && k < level.layout.vents.count else { return }
            if k < ventFlare.count { ventFlare[k] = 1.2 }
            let v = level.layout.vents[k], gy = level.groundY(v.x, v.y)
            fx.gpu.burst(.ice, 10, at: F3(v.x, gy + 0.25, v.y), vel: F3(0, 1.8, 0), velJitter: F3(1.2, 0.8, 1.2), life: (0.4, 0.8),
                         size: (0.06, 0.03), color: F4(0.6, 0.8, 0.9, 1), gravity: 4, drag: 1.2)
            fx.flash(F3(v.x, gy + 0.4, v.y), F3(1.0, 0.45, 0.12), peak: 30, dur: 0.4, range: 5, priority: 12)
        case .ventSealed(let k):
            guard k >= 0 && k < level.layout.vents.count else { return }
            let v = level.layout.vents[k], gy = level.groundY(v.x, v.y)
            fx.gpu.burst(.spark, 14, at: F3(v.x, gy + 0.2, v.y), vel: F3(0, 1.4, 0), velJitter: F3(1.8, 1.2, 1.8), life: (0.2, 0.45),
                         size: (0.03, 0.02), color: F4(1.3, 1.0, 0.6, 1), gravity: 8, drag: 1.2)
            fx.flash(F3(v.x, gy + 0.6, v.y), F3(1.0, 0.8, 0.5), peak: 40, dur: 0.3, range: 6, priority: 14)
        default:
            break
        }
    }

    /// Once a second (diagnostics), a mission with its own plan: `hb mission <id> step=k/n <module> <phase> switches=… vents
    /// shut=… stream=… hold=… lit=…`.
    private func heartbeat(_ game: Game) {
        guard AppLog.diagnostics, game.mission.id != MissionTemplate.coldLight.id else { return }
        let now = FrameTimer.now()
        if now - lastLog < 1 { return }
        lastLog = now
        let sw = game.switches.map { s -> String in s.state == 2 ? "x" : (s.state == 1 ? String(format: "%.2f", s.progress) : "o") }
        AppLog.info(String(format: "hb mission %@ step=%d/%d %@ %@ switches=%@ vents shut=%d stream=%.2f hold=%.1f lit=%d/%d", game.mission.id,
                           game.missionStep + 1, game.mission.steps.count, game.currentModule?.rawValue ?? "-",
                           game.stepPhase == .active ? "active" : "approach", sw.joined(separator: ","), game.ventShut.filter { $0 }.count,
                           game.streamK, game.holdActive ? game.liftT : Float(-1), game.lightsLit, game.circuits.count))
    }
}
