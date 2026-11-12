import Foundation
import IceHiveCore

// ================================================================
//  DEMO SCRIPTS — scripted scenarios for CI screenshots / perf logs:
//    -demo combat   mission (assault unless -class), squad invulnerable, autopilot, a crowd spawned around the
//                   squad and kept topped up: 600, but never more than the mission's live cap (native-vx-feel: 250 on
//                   Medium — the wave pacing's peak; `-bugs N` asks for N past the cap: the renderer stress runs)
//    -demo beacon   mission started next to beacon «Alpha» with a crowd (350, under the live cap like combat)
//    -demo title    the title screen (attract mode behind)
//    -demo calm     mission start with the director off: no bugs, the squad idles on the
//                   landing pad (lighting / station look)
//    -demo layout   like calm; 1 s after «scene ready» every screen is laid out and checked on the four
//                   landscape phones (LayoutSizes: «layout ok|FAIL …», «layout sizes: N ok, M FAIL»)
//    -demo smoke    alias of combat (the original CI scenario name)
//    -demo probe    combat, plus one horde ingredient every 4 s (overlay, banner, shake, sounds,
//                   haptic, then a real horde) — CI hitch attribution
//    -demo hold     beacons skipped, the squad on the lift holding out against the hold's own swarm (native-vx-feel:
//                   nothing spawned by the demo — the director's opening horde, a third of it over the lift's rim)
//    -demo extract  like hold, then the lift rises and stays at extract + 2 s (gore rides along)
//    -demo queen    like hold, and the Queen (v1.1 boss of the hold) climbs up 2 s after «scene ready» (1 000 000 HP
//                   unless -queenHp, so she stays on the deck for the screenshot)
//    -demo queenlock  queen, then the lift countdown runs out 1.5 s later: «Lift locked — the Queen lives»
//    -demo coach    the first mission ever on the fresh demo profile: «Учебная высадка» runs (autopilot off, so the
//                   steps advance by their timeouts; -coachStep N jumps), the next step 1.5 s after «scene ready»,
//                   then time almost stopped so the screenshot shows that step
//    -demo pressure Ветеран, nobody touches the screen: fast-forward to 15.5 s, the hive pressure then pinned in the
//                   amber band (-pressure amber), or amber until 1.5 s after «scene ready» and then red
//    -demo report   the mission report of a fixture (-report first|win|loss|chip): the run's outcome is forced and
//                   committed into the demo's in-memory profile 2 s after «scene ready»
//    -demo levelup  a forced level-up 2 s after «scene ready»: the upgrade cards
//    -demo pause    the pause menu 2 s after «scene ready»
//    -demo end      surrender 2 s after «scene ready»: the mission report (record highlight on)
//  (the v1.1 state changes come inside the frame gate's window, from 1.2 s after «scene ready»: their first draw is
//  measured, not hidden in the first second)
//    -demo swarmshot  the App Store 2-swarm moment (harness/scenarios/store-shots.mjs (b)):
//                   gunner, 12 s into the mission, the squad at the crossing (0, -5), a few
//                   steps, a crowd around it (the store's 600 under the live cap: 350 on «high»),
//                   the player aiming up-left and firing for 1.6 s, then time almost frozen (×0.02)
//                   for the screenshot
//  WP7 «Режиссура» (look-dev, cinematics, device capture):
//    -demo stress1400  the device capture: 1400 live bugs around the squad (-bugs N), «высокая» (High), kept topped up —
//                   `hb gpu` per-pass lines on a device; A/B with -noSwarmDraw / -noStation / -fxSim off / -nocones
//    -demo bugsheet  every bug type × clip around the camera focus (WorldSwarm's sheet; -bugsheet [scale],
//                   -bugsheetGame, -bugsheetT s, -bugstrip <type> [scale] as on `-demo calm`), director off
//    -demo punchin  the squad in beacon «Alpha»'s ring with a crowd; 1.5 s after «scene ready» the beacon comes on →
//                   Cinematics' punch-in (push-in at the game yaw, ×0.3 time for ≈ 0.45 s, 2.4 s); at 4.6 s it plays
//                   again and holds at its peak (0.95 s in) with the world nearly frozen, for the screenshot
//    -demo extract-cine  the hold on the lift with a crowd; at 1.5 s the lift leaves → the extraction shot from the
//                   shaft wall; the lift pinned 2.8 s into its rise for the screenshot
//  Every demo drives Cinematics (mood, shot EV, dilation) until GameScene does; `-cine off` keeps the game camera.
//  native-vx-feel (wave pacing):
//    -demo waves    the game's own swarm, nothing spawned by the demo: the squad in beacon «Beta»'s ring (`-waveBeacon k`
//                   picks another), the defence's opening horde from 3–4 sides, the ring charged to 27 % so the hive's
//                   first push (30 %) lands 2 s later; time almost frozen (×0.02) at `-waveFreeze` s (6.5) after «scene
//                   ready» for the screenshot. Logs `demo waves: td=… alive … near16 … pushes …` once a second.
//  native-vx-swarm-life (a living swarm — the CI bursts burst-pack / burst-mix, A/B with -swarmLegacy):
//    -demo swarmpack  the squad on beacon «Alpha»'s platform (open deck, as `beacon`), a runner pack (60) spread over
//                   the deck 5–11 m around it rushing in, kept topped up from the walkways (11–17 m); the director off,
//                   the player idle, the squad firing (deaths by cause: shots, flames, frost, grenades)
//    -demo swarmmix   the same with a mixed pack (75, every type)
//  feel build A3 (the actions):
//    -demo defeat   a crowd round the squad (200, under the live cap), then the squad goes down one by one from 2.0 s
//                   after «scene ready» (0.6 s apart, the player last, invulnerability off for it): the core loses the
//                   mission, GameScene plays the defeat beat (the deaths, Cinematics' push-in, 2.8 s) and the report
//                   comes up — the CI burst burst-defeat and the screenshot after it
//  Stage 1 R2 «Overhead core» / R3 «Overhead render»:
//    -demo overhead  «Кельвин-9» with the overhead showcase laid (OverheadShowcase: R2's slice — a 4.5 m rack on the far
//                   rail of the pad → hub bridge, an abyss riser, a duct mouth — plus two cantilever arms and a cable over
//                   the walkway, a pipe bridge into the void, a catwalk, the stair-chute tray; drawn by WorldOverhead),
//                   the director off, the player idle mid-bridge, the bots holding fire. 1.0 s after «scene ready» a pack
//                   of 6 climbs the riser, at 4.0 s 5 pour out of the duct mouth: they ride the rack (and the arm and the
//                   cable over the squad) and drop on it (`route: drop warned / landed` lines, the `.dropZone` rings, the
//                   frost-dust streams and red glints); the bots open fire at 6.0 s (`route: killed up there`); time
//                   almost frozen (×0.02) on a drop telegraph from 7.0 s (at 9.0 s at the latest) for the screenshot. Once
//                   a second `hb route alive=… up=… states=… drops=…`. `-ohWalk` (the parallax burst): the squad starts at
//                   the pad end and the player walks the bridge toward the hub from 1.0 s (no freeze) — the camera follows,
//                   the deck, the routes and the upper truss slide past at their three speeds. `-ohHigh`: on «высокая»
//                   (the flashlight shadows: the overhead's casters in the player's tile — the CI parallax burst).
//  Stage 1 R4 «Overhead bugs»:
//    -demo overheadbugs  the overhead showcase (as -demo overhead), the squad mid-bridge, the director off, the bots holding
//                   fire, the player an idle assault (god mode: pinned, never hurt) and every route bug's target (on the sim
//                   clock — `ts`, sim seconds since «scene ready»; the log lines give td as well). At 0.3 s a Dropper is
//                   sent to the duct mouth: the grille rattles 2 s, it pours out, rides the rack toward the player,
//                   telegraphs (coil: its front third curls down over the edge, the ring, the frost column) and drops: the
//                   player is PINNED (`bugs: pinned …`) — the bots open fire and shoot it off (`bugs: pin broken … by fire`).
//                   At 1.0 s a spitter climbs the pad's post and perches over the void on the far arm (`bugs: spitter
//                   perched`), spitting from height. At 5.4 s a pack is sent to the duct mouth: it rattles and the player
//                   shoots it shut through the aim assist (`bugs: duct 0 shot shut`; the pack is lost). At 6.0 s a second
//                   Dropper climbs the riser and pins the player: time almost frozen (×0.02) 0.25 s into that pin for the
//                   screenshot (the «Pinned — dash!» hint); `-obDash`: no freeze — the player dashes out 0.45 s into it
//                   (`… by dash`; the CI burst burst-dash). Once a second `hb bugs droppers=… pins=… perched=… ducts=…`.
//  Stage 1 R6 «Valves, light, lockers»:
//    -demo interactives  «Кельвин-9» with its interactives laid (PropLayout.kelvinDemo: Kelvin-9's steam valves, seven light
//                   circuits with breakers, a supply locker, plus a coolant line on the hub's west rail) and the overhead's
//                   demo slice (the rack the bridge valve sits on), the
//                   director off, the player idle on the near side of the pad → hub bridge's hub end (the valve's whole
//                   span, the coolant line, the hub breaker and the locker in frame), the squad firing. 0.8 s after
//                   «scene ready» a runner pack spawns at the pad end of the bridge under the valve's span and runs along
//                   it; the gunner pops the valve once 6 are under it (else the demo does, by the same rule from 1.0 s,
//                   at 1.8 s at the latest): the
//                   burst, then the 5 s scald curtain (CI burst burst-valve); at 3.0 s a second pack on the hub's west strip
//                   under the coolant line, popped at 3.6 s unless the squad did: 2 s of freezing mist. At 8.0 s the hub's circuit is cut (its lamps
//                   die), from 8.5 s the player walks into the hub breaker's ring and stands there; 6 s in the ring bring
//                   the lights back, lamp by lamp from the breaker (CI burst burst-lights). `-ixLights`: the lights only —
//                   the squad on the hub's centre, no pack, no valve, the cut at 1.0 s and the walk from 1.5 s (a shorter
//                   burst run: the lights back ≈ 8.5 s in). `props: …` lines on
//                   every prop event, `hb props …` and `demo interactives: …` once a second.
//  Stage 1 R7 «Missions I» (each plays its mission on its own station — Kelvin-9 Mk II, the classic mission's: its overhead
//  routes and props — autopilot, squad invulnerable, the director on):
//    -demo breakerrun  Breaker Run in the dark (M1: four breakers, 55 s contested rings): the squad put into the ring of the
//                   hub's breaker — the fourth, between the pad, beacon A's catwalk and the stairs down to the plaza, under
//                   the Spine Rack's cable span — so the hive's surge answers on the first tick and the squad fights it in
//                   the ring; 6 s after «scene ready» the demo jumps the ring to 0.99 and keeps it there (quietly: the hive's
//                   pushes below it count as done; the squad put into it again after 2.5 s), the breaker is thrown the next
//                   moment anyone stands in the ring — the hub lights up lamp by lamp from the breaker while the bridge and
//                   the stairs beyond stay dark — and time almost stops 1.6 s after it (at 15.5 s at the latest) for the
//                   screenshot («RESTORE POWER 1/4»). Nothing waits on the autopilot's walk or on a draining ring.
//                   `demo breakerrun: …` once a second, `mission: …` / `props: …` lines, `hb mission …`
//    -demo ventpurge   Vent Purge (M1: a duct mouth that must be held shut): the squad put into the seal ring under the hub →
//                   A walkway's duct mouth; the weld waits for the grille shot shut («SHOOT THE DUCT SHUT»), the player
//                   shoots it shut (the demo does it 3 s after «scene ready» if the player has not) and the weld fills while
//                   the squad fights the hive's surge; 6 s after «scene ready» (1.5 s after the shut at the earliest) the demo
//                   jumps the weld to 0.6 (quietly, and keeps it there) and lets the hive chew through the grille early (the
//                   game's own wait is 10 s): the weld waits once more and the player's rounds go up at the mouth — time
//                   almost stops 0.3 s after it opens again (at 15.5 s at the latest) for the screenshot. Nothing waits on
//                   the autopilot's walk, a draining ring or the 10 s; nothing is staged before «scene ready» (the sim runs
//                   under the loading cover). `demo ventpurge: …` once a second, `mission: …` / `bugs: duct …` lines,
//                   `hb mission …`
//  R0 (film fixes):
//    -demo win      like hold; 1 s after «scene ready» the lift leaves and the ride plays out to the win (4.6 s): the
//                   report comes up at once and the world keeps animating under it (the lift eases to a stop with the
//                   extraction camera, the squad's victory, the effects) — the CI burst burst-win (HUD off: the world)
//    No demo shows more live bugs than the game itself can: every forced crowd is clamped to the mission's live cap
//    (`crowd(_:)`; the wave pacing's High 350 / Medium 250 / Low 220 under the device class), the hold demos play the
//    director's own hold. Only the declared renderer stress runs go past it — stress1400 (1400) and an explicit
//    `-bugs N` (CI `swarm` / `swarm3x`: 1400).
// ================================================================
final class DemoScript {
    let name: String
    private var t: Float = 0
    private var topUpT: Float = 0
    private var target = 600
    /// `-bugs N`: swarm size of the combat / beacon demos (renderer stress runs).
    private var override: Int?
    /// Live-bug cap of the mission (set in `begin`): the forced crowds stay under it (`crowd`).
    private var cap = Int.max

    /// A forced crowd of `n` as the game could have it: at most the mission's live cap (the wave pacing's peak), unless
    /// `-bugs N` asks for a renderer stress crowd past it.
    private func crowd(_ n: Int) -> Int { override ?? min(n, cap) }

    private let options: LaunchOptions
    /// Seconds since «scene ready» (the scene sets it before every frame; -1 while loading). Also published as
    /// `sceneClock` for the squad look-dev (feel build A2): its scripted beats then land in the CI bursts' windows, which
    /// count from «scene ready» too (the render clock starts under the loading cover, a few seconds earlier).
    var sinceReady: Double = -1 { didSet { DemoScript.sceneClock = sinceReady } }
    /// The running demo's `sinceReady` (-1 with no demo or while loading).
    private(set) static var sceneClock: Double = -1
    private var queenSet = false, coachStepped = false
    /// `-demo win`: the hold has been ended (the lift leaves on the next ticks).
    private var winLeft = false
    private var defeatStep = 0
    /// `-demo report`: the fixture whose outcome the mission gets.
    let reportFixture: DemoFixtures.Report?

    private init(name: String, options: LaunchOptions, bugs: Int? = nil) {
        self.name = name
        self.options = options
        override = bugs
        reportFixture = name == "report" ? DemoFixtures.report(options.report) : nil
        if name == "report" && reportFixture == nil { AppLog.error("unknown -report \(options.report ?? "?")") }
    }

    static func make(options: LaunchOptions) -> DemoScript? {
        guard let d = options.demo else { return nil }
        switch d {
        case "combat", "smoke", "default": return DemoScript(name: d == "default" ? "combat" : d, options: options, bugs: options.bugs)
        case "beacon": return DemoScript(name: d, options: options, bugs: options.bugs)
        case "title", "calm", "probe", "hold", "holdhint", "extract", "queen", "queenlock", "coach", "pressure", "report", "levelup", "pause", "end",
             "swarmshot", "layout", "bugsheet", "punchin", "extract-cine", "waves", "swarmpack", "swarmmix", "defeat", "overhead", "win",
             "overheadbugs", "interactives", "breakerrun", "ventpurge":
            return DemoScript(name: d, options: options)
        case "stress1400": return DemoScript(name: d, options: options, bugs: options.bugs ?? 1400)
        default:
            AppLog.error("unknown demo \(d), using combat")
            return DemoScript(name: "combat", options: options)
        }
    }

    /// Mission tier of the demo unless `-tier` says otherwise: the report fixture's, the first-run rule for the coach
    /// (nil = the scene asks the demo profile), else Ветеран.
    var defaultTier: Int? {
        if let r = reportFixture { return r.tier }
        return name == "coach" ? nil : 1
    }

    var startsMission: Bool { name != "title" }

    /// Stage 1 R7: the mission the demo plays (its station is the level: GameScene builds it from the mission).
    var mission: MissionTemplate? {
        switch name {
        case "breakerrun": return .breakerRun
        case "ventpurge": return .ventPurge
        default: return nil
        }
    }

    /// The station the demo plays (nil = the classic mission's «Кельвин-9» Mk II): the overhead demos lay the overhead
    /// showcase, the interactives demo the slice and R6's demo props.
    var levelSource: LevelSource? {
        // (R6: the interactives demo lays «Кельвин-9»'s props and the slice its bridge valve hangs on)
        if name == "interactives" { return KelvinStation(overhead: .kelvinSlice, props: .kelvinDemo) }
        return name == "overhead" || name == "overheadbugs" ? KelvinStation(overhead: OverheadShowcase.layout) : nil
    }
    /// `-ohWalk`: the overhead demo's parallax walk (the CI burst `burst-parallax`).
    private var walk: Bool { options.unknown.contains("-ohWalk") }

    /// Class the demo plays unless `-class` says otherwise (the store shot is the gunner's).
    var preferredClass: String? { name == "swarmshot" ? "gunner" : (name == "overheadbugs" ? "assault" : nil) }

    /// Graphics tier the demo forces without touching the saved setting (the store shots and the WP7 cinematics are
    /// taken on «высокая»; stress1400 is the plan's High budget run).
    var preferredQuality: String? {
        if name == "overhead" && options.unknown.contains("-ohHigh") { return "high" }
        return ["swarmshot", "stress1400", "punchin", "extract-cine", "win"].contains(name) ? "high" : nil
    }

    /// World time scale the scene applies on top of hit-stop: the demo's freeze (swarmshot, coach, the held punch-in:
    /// ×0.02) × the punch-in's time dilation while the demo drives Cinematics.
    var timeScale: Float {
        let c = Cinematics.shared
        return freeze * (c.drivenByScene ? 1 : c.timeScale)
    }
    private var freeze: Float = 1
    private var shotStage = 0
    private var cineStep = 0

    /// Called right after the mission starts.
    func begin(game: Game) {
        cap = game.bugCap
        game.godMode = true
        game.autopilot = true
        game.autoPickUpgrades = true
        Cinematics.shared.reset()
        switch name {
        case "calm", "layout", "bugsheet":
            game.autopilot = false
            game.directorEnabled = false
            target = 0
            AppLog.info("demo \(name): director off, squad idle")
        case "hold", "holdhint", "extract", "queen", "queenlock", "extract-cine", "win":
            var guardN = 0
            while game.stage == .beacons && guardN < 6 { game.debugSkip(); guardN += 1 }
            if game.stage == .toLift { game.debugSkip() }
            // native-vx-feel: the hold's own swarm — the director's opening horde (packs from the ramp and the deck, a
            // third straight over the lift's rim), a horde every 18–24 s; the extraction shot keeps its crowd (gore on the
            // lift as it rises)
            target = name == "extract-cine" ? crowd(260) : 0
            // (extract-cine: on the lift's two flanks as the extraction camera sees them, 4–9 m out — `crowdFlanks`)
            var n = 0
            if target > 0 {
                if let fl = crowdFlanks {
                    n = game.debugSpawn(target / 2, type: nil, minRadius: 4, maxRadius: 9, sector: fl.0)
                        + game.debugSpawn(target - target / 2, type: nil, minRadius: 4, maxRadius: 9, sector: fl.1)
                } else {
                    n = game.debugSpawn(target, type: nil, minRadius: 5, maxRadius: 18)
                }
            }
            AppLog.info("demo \(name): stage \(game.stage.rawValue), spawned \(n) bugs around the lift (bug cap \(game.bugCap))")
        case "coach":
            // a novice who does not touch the screen: every step ends by its timeout
            game.autopilot = false
            target = 0
            // one step before the asked one (-coachStep N, else step 0 → 1): the step change is drawn inside the gate window
            if let k = options.coachStep, k > 0 { game.debugCoachStep(k - 1) }
            AppLog.info("demo coach: coach \(game.coach.active ? "on" : "off") step \(game.coach.step) tier=\(game.difficulty.id)")
        case "pressure":
            game.autopilot = false
            target = 0
            game.fastForward(seconds: 15.5)
            AppLog.info(String(format: "demo pressure: t=%.1f pressure %.1f threat %d tier=", game.time, game.pressure, game.threatState.rawValue)
                        + game.difficulty.id)
        case "report":
            target = crowd(300)
            let n = game.debugSpawn(target, type: nil, minRadius: 6, maxRadius: 24)
            AppLog.info("demo report \(reportFixture?.name ?? "-"): spawned \(n) bugs, tier=\(game.difficulty.id)")
        case "swarmshot":
            game.autopilot = false
            target = 0
            AppLog.info("demo swarmshot: staging the store 2-swarm moment")
        case "swarmpack", "swarmmix":
            game.autopilot = false
            game.directorEnabled = false
            if let b = game.beacons.first { game.debugTeleport(b.x + 3, b.z - 3.5) }
            target = crowd(name == "swarmpack" ? 60 : 75)
            let n = game.debugSpawn(target, type: packType, minRadius: 5, maxRadius: 11)
            AppLog.info("demo \(name): spawned \(n) bugs (\(packType.map { "\($0)" } ?? "mixed")) on beacon Alpha's deck, swarm "
                        + (SwarmAnimator.legacy ? "legacy" : "life"))
        case "defeat":
            target = crowd(200)
            let n = game.debugSpawn(target, type: nil, minRadius: 7, maxRadius: 22)
            AppLog.info("demo defeat: spawned \(n) bugs, the squad goes down from 2.0 s")
        case "levelup", "pause", "end":
            if name == "levelup" { game.autoPickUpgrades = false }
            target = crowd(300)
            let n = game.debugSpawn(target, type: nil, minRadius: 6, maxRadius: 24)
            AppLog.info("demo \(name): spawned \(n) bugs")
        case "stress1400":
            target = override ?? 1400
            let n = game.debugSpawn(target, type: nil, minRadius: 6, maxRadius: 30)
            AppLog.info("demo stress1400: spawned \(n) bugs (target \(target), cap \(game.bugCap)), quality high — device capture: hb gpu per-pass lines")
        case "punchin":
            // inside beacon «Альфа»'s ring (the squad charges it; the demo then completes it)
            if let b = game.beacons.first { game.debugTeleport(b.x + 1.5, b.z - 1.5) }
            target = crowd(300)
            let n = game.debugSpawn(target, type: nil, minRadius: 8, maxRadius: 24)
            AppLog.info("demo punchin: squad in beacon \(game.beacons.first.map { $0.name.logID } ?? "?")'s ring, spawned \(n) bugs")
        case "overhead":
            // Stage 1 R2: mid-bridge under the demo rack (its far rail 3.6 m up-screen), nobody firing until the drops start
            // (R3 -ohWalk: at the bridge's pad end, the player walks it toward the hub)
            game.autopilot = false
            game.directorEnabled = false
            game.debugHoldFire = true
            if walk { game.debugTeleport(21.5, 31.6) } else { game.debugTeleport(14, 30.5) }
            target = 0
            let G = game.level.overhead
            let rc = OverheadCheck.check(game.level.layout.overhead, level: game.level)
            AppLog.info("demo overhead: routes \(G?.edgeCount ?? 0) edges, \(G?.entries.count ?? 0) entries, squad "
                        + (walk ? "at the pad end, walking to the hub" : "mid-bridge") + ", director off, bots holding fire"
                        + String(format: " | routeCheck %@ (%.0f m, footprint %.1f %%)", rc.ok ? "ok" : "FAIL " + rc.why, rc.length, rc.footprint * 100))
        case "overheadbugs":
            // Stage 1 R4: mid-bridge under the showcase's rack (the riser right above the squad), the bots holding fire
            game.autopilot = false
            game.directorEnabled = false
            game.debugHoldFire = true
            game.debugTeleport(14, 30.5)
            // (the Droppers go for the player: the demo shows its pin, the hint and the squad's answer)
            game.debugRouteFocus = 0
            target = 0
            let G = game.level.overhead
            AppLog.info("demo overheadbugs: routes \(G?.edgeCount ?? 0) edges, \(game.ducts.count) duct mouths, \(game.perchPoints.count) perch points, "
                        + "squad mid-bridge, director off, bots holding fire" + (options.unknown.contains("-obDash") ? ", the player dashes out of the pin" : ""))
        case "interactives":
            // Stage 1 R6: the near side of the pad → hub bridge's hub end, off the valve's curtain; the squad fires
            game.autopilot = false
            game.directorEnabled = false
            // (-ixLights: the hub's centre, 6 m from its breaker)
            if ixLightsOnly { game.debugTeleport(0.5, 28) } else { game.debugTeleport(8, 31.5) }
            target = 0
            AppLog.info("demo interactives: \(game.valves.count) valves, \(game.circuits.count) circuits, \(game.lamps.count) lamps, "
                        + "\(game.lockers.count) lockers; lit \(game.lightsLit)/\(game.circuits.count); squad on the bridge's hub end")
        case "breakerrun":
            // M1: in the ring of the hub's breaker (the fourth; 1.1 m east of the cabinet, as R7's put-in): it starts at once
            if let w = game.switches.first(where: { $0.site.kind == .breaker && $0.site.z > 15 && $0.site.x > -10 && $0.site.x < 8 }) {
                game.debugTeleport(w.site.x + 1.1, w.site.z)
            }
            target = 0
            AppLog.info("demo breakerrun: \(game.mission.id), lit \(game.lightsLit)/\(game.circuits.count), \(game.switches.count) breakers; "
                        + "squad in the hub breaker's ring")
        case "ventpurge":
            // M1: in the seal ring under the hub → A walkway's duct mouth (duct 1): it starts at once
            if let w = game.switches.first(where: { $0.site.duct == 1 }) { game.debugTeleport(w.site.x, w.site.z) }
            target = 0
            AppLog.info("demo ventpurge: \(game.mission.id), \(game.switches.count) seals: "
                        + game.switches.map { $0.site.duct >= 0 ? "duct \($0.site.duct)" : "vent \($0.site.vent)" }.joined(separator: ", ")
                        + "; squad in the seal ring under duct 1")
        case "waves":
            // the wave director's own swarm: the squad in a beacon's ring, its defence starts on the first tick
            let k = max(0, min(game.beacons.count - 1, Int(demoNum("-waveBeacon", 1))))
            if k < game.beacons.count { let b = game.beacons[k]; game.debugTeleport(b.x + 1.5, b.z - 1.5) }
            target = 0
            AppLog.info("demo waves: squad in beacon \(k)'s ring, the director's own swarm (bug cap \(game.bugCap))")
        case "beacon":
            if let b = game.beacons.first {
                game.debugTeleport(b.x + 3, b.z - 3.5)
            }
            target = crowd(350) - overheadRoom(game)
            let n = game.debugSpawn(min(target, 600), type: nil, minRadius: 7, maxRadius: 24)
            AppLog.info("demo beacon: squad at beacon \(game.beacons.first.map { $0.name.logID } ?? "?"), spawned \(n) bugs")
        default:
            target = crowd(600) - overheadRoom(game)
            let n = game.debugSpawn(min(target, 900), type: nil, minRadius: 6, maxRadius: 26)
            AppLog.info("demo \(name): spawned \(n) bugs around the squad (target \(target), bug cap \(game.bugCap))")
        }
        logOverhead(game)
    }

    /// Probe steps due this frame (executed by the scene: HUD / audio / haptics live there).
    enum Probe: String { case overlay, banner, shake, sounds, haptic, horde }
    /// Screen changes the scene performs for a demo (one frame); `layoutSizes`: `-demo layout` checks every screen on
    /// the four landscape phones (LayoutSizes).
    enum Request { case pause, surrender, end, layoutSizes }
    private(set) var request: Request? = nil
    private var requested = false
    private let probeSteps: [Probe] = [.overlay, .banner, .shake, .sounds, .haptic, .horde]
    private var probeIndex = 0
    private(set) var probe: Probe? = nil

    /// Per frame while the mission runs: keep the swarm at `target` (the squad kills ~100 bugs a second, so
    /// replacements arrive twice a second from 12–30 m away and walk in).
    func frame(game: Game, dt: Float) {
        Cinematics.shared.update(game: game, dt: dt, by: .demo)
        if name == "punchin" { punchIn(game) }
        if name == "extract-cine" { extractCine(game) }
        if name == "swarmshot" { swarmShot(game); return }
        if name == "layout" {
            request = nil
            if !requested && sinceReady >= 1 { requested = true; request = .layoutSizes }
            return
        }
        if name == "coach" || name == "pressure" { holdState(game, dt); return }
        if name == "waves" { waves(game, dt); return }
        if name == "overhead" { overhead(game, dt); return }
        if name == "overheadbugs" { overheadBugs(game, dt); return }
        if name == "interactives" { interactives(game, dt); return }
        if name == "breakerrun" { breakerRun(game, dt); return }
        if name == "ventpurge" { ventPurge(game, dt); return }
        if !startsMission { return }
        t += dt
        probe = nil
        request = nil
        overheadInPlay(game, dt)
        if !requested && t >= 1.5 && sinceReady >= 2 {
            switch name {
            case "levelup": requested = true; game.debugLevelUp()
            case "pause": requested = true; request = .pause
            case "end": requested = true; request = .surrender
            case "report":
                requested = true
                if let r = reportFixture { DemoFixtures.apply(r, to: game) }
                request = .end
            default: break
            }
        }
        if name == "defeat" {
            // the squad down one by one (the player last): the core ends the mission when the last one is down
            let at: [Double] = [2.0, 2.6, 3.2, 3.8]
            while defeatStep < 4 && sinceReady >= at[defeatStep] {
                game.godMode = false
                let k = 3 - defeatStep
                game.debugHurt(marine: k, hp: 0)
                defeatStep += 1
                AppLog.info("demo defeat: marine \(k) down")
            }
        }
        if (name == "queen" || name == "queenlock") && !queenSet && sinceReady >= 2 {
            queenSet = true
            // (the scene logs «v11 queen spawn …» from her event)
            let uid = game.debugBoss(hp: options.queenHp ?? 1_000_000)
            if uid == 0 { AppLog.info("demo \(name): the Queen did not come (stage \(game.stage.rawValue))") }
        }
        if name == "queenlock" && !lockSet && queenSet && sinceReady >= 3.5 {
            lockSet = true
            game.debugSetLiftTime(0.01)
            AppLog.info("demo queenlock: lift countdown out, queen alive=\(game.boss.alive)")
        }
        // holdhint: the countdown pinned in its first 8 s, so the tier's lift-pulse hint («Контур бьёт каждые 6 с — …»,
        // two lines on a phone) stays up for the screenshot taken after the measured window (mission time ≥ 7 s)
        if name == "holdhint" && game.stage == .hold { game.debugSetLiftTime(LIFT_TIME - 3) }
        if name == "extract" {
            if game.stage == .hold && t >= 6 { game.debugSkip() }
            if game.stage == .extract { game.debugPinExtract(2.0) }
        }
        if name == "win" && !winLeft && game.stage == .hold && sinceReady >= 1 {
            // (R0: the ride is not pinned — it plays out to the win, and the scene brings the report up over the live world)
            winLeft = true
            game.debugSkip()
            AppLog.info(String(format: "demo win: lift leaves td=%.2f stage %d", sinceReady, game.stage.rawValue))
        }
        if name == "probe" && probeIndex < probeSteps.count && t >= Float(4 * (probeIndex + 1)) {
            probe = probeSteps[probeIndex]
            probeIndex += 1
        }
        topUpT -= dt
        if target > 0 && topUpT <= 0 {
            topUpT = 0.5
            let alive = game.bugsAlive
            if alive < target - 10 {
                let k = min(300, target - alive)
                // (extract-cine: the top-ups climb over the lift's rim on either flank in turn, the hold's own entrance)
                flankTurn.toggle()
                let pack = name == "swarmpack" || name == "swarmmix"
                let n = climbFlanks.map { game.debugClimbLiftRim(k, sector: flankTurn ? $0.0 : $0.1) }
                    ?? game.debugSpawn(k, type: packType, minRadius: pack ? 11 : 12, maxRadius: pack ? 17 : 30)
                spawned += n
            }
            logT -= 0.5
            if logT <= 0 {
                logT = 5
                AppLog.info("demo \(name): alive \(game.bugsAlive), topped up \(spawned) in the last 5 s")
                spawned = 0
            }
        }
    }
    private var spawned = 0
    private var logT: Float = 5

    // ---------- Stage 1 R5: the overhead in play in the classic demos ----------
    /// The classic demos play «Кельвин-9» Mk II: combat, beacon, hold and queen send packs up the overhead entries near the
    /// squad by the director's own rule (`debugRoutePack` with no entry: a riser, a mast or a duct mouth 8–20 m away whose
    /// routes pass near it) — a runner pack, a Dropper and (off the lift: no perch there) a spitter for a perch — from 0.5 s,
    /// again every 5 s while fewer than 8 are up, so the CI shots show the overhead in play, not only its geometry.
    private static let overheadDemos: Set<String> = ["combat", "beacon", "hold", "queen"]
    private var ohT: Float = 0.5
    /// Room the forced deck crowd leaves under the live cap for the overhead's bugs (route bugs count toward the cap).
    private func overheadRoom(_ game: Game) -> Int {
        DemoScript.overheadDemos.contains(name) && game.level.overhead != nil && override == nil ? 24 : 0
    }
    /// The station's overhead at the start of a classic demo (CI checks it): its routes, entries, duct mouths, perches and
    /// routeCheck in the full set's band.
    private func logOverhead(_ game: Game) {
        guard DemoScript.overheadDemos.contains(name), let G = game.level.overhead else { return }
        let rc = OverheadCheck.check(game.level.layout.overhead, level: game.level, lengthBand: KelvinMk2.lengthBand)
        AppLog.info("demo \(name): \(game.level.layout.overhead == .kelvinMk2 ? "Kelvin-9 Mk II" : "a station") overhead, \(G.edgeCount) edges, "
                    + "\(G.entries.count) entries, \(game.ducts.count) duct mouths, \(game.perchPoints.count) perch points, \(game.valves.count) valves, "
                    + "\(game.circuits.count) circuits" + String(format: " | routeCheck %@ (%.0f m, footprint %.1f %%)", rc.ok ? "ok" : "FAIL " + rc.why,
                                                                rc.length, rc.footprint * 100))
    }
    private func overheadInPlay(_ game: Game, _ dt: Float) {
        // (from «scene ready»: while loading the squad is not where the demo puts it — the hold's first pack found no entry)
        guard DemoScript.overheadDemos.contains(name), game.level.overhead != nil, sinceReady >= 0 else { return }
        ohT -= dt
        if ohT > 0 { return }
        ohT = 5
        let lift = game.stage == .hold || game.stage == .extract
        var r = 0, d = 0, s = 0
        if game.routeAlive < 8 {
            r = game.debugRoutePack(6, rate: 3)
            d = game.debugRoutePack(1, rate: 1, type: .dropper)
            s = lift ? 0 : game.debugRoutePack(1, rate: 1, type: .spitter)
        }
        let c = game.overheadStateCounts
        AppLog.info(String(format: "demo %@: overhead td=%.2f sent runners %d dropper %d spitter %d · up %d (high %d riser %d coil %d perch %d) "
                           + "drops %d", name, sinceReady, r, d, s, game.routeAlive, c[0], c[1], c[2], c[6], game.overheadStats.drops))
    }
    /// extract-cine: the crowd (on the deck, 4–9 m out) and its top-ups (over the rim, the hold's own entrance) on the
    /// lift's two flanks as seen from the extraction camera (Cinematics: the eye on the shaft wall at MetalCamera.yaw + 20°),
    /// ±50° around the perpendiculars: the squad fires across the frame, lit side-on, as in the shots before the wave pacing.
    /// (native-vx-feel: with the crowd all round, the squad's flashlights swept the eye and the shot dodged them to its
    /// −45° / +12° limit — median 62.8 on 01c636a, clip 1.24 % on c500515's first shot —; with the crowd on the far side the
    /// squad turned its back and lit only the far deck — near-black 40.9 % on 25f5e4a's first shot; 58e10b3 spawned the
    /// top-ups 12–30 m out, off the lift, and they walked round to the ramp on the camera's side.)
    private var crowdFlanks: ((angle: Float, half: Float), (angle: Float, half: Float))? {
        guard name == "extract-cine" else { return nil }
        let yaw = MetalCamera.yaw + Cinematics.extraction.yawOffDeg * .pi / 180
        let toEye = atan2f(cosf(yaw), sinf(yaw)), half: Float = 50 * .pi / 180
        return ((toEye + .pi / 2, half), (toEye - .pi / 2, half))
    }
    /// extract-cine: the top-ups' rim climbs on the far part of each flank, 75–145° from the camera's bearing (the deck
    /// crowd keeps `crowdFlanks`). (feel-build review: climbing 40° from the bearing, with the shot's cone dodge swinging
    /// the eye up to 45° round, a brute came over the rim beside the lens and blacked out a fifth of the frame — the
    /// extraction's near-black 36–41 % first shots on 79eef3f, 9c93169, e765953, 45cc4c2, 8f1e677, 067cd21.)
    private var climbFlanks: ((angle: Float, half: Float), (angle: Float, half: Float))? {
        guard name == "extract-cine" else { return nil }
        let yaw = MetalCamera.yaw + Cinematics.extraction.yawOffDeg * .pi / 180
        let toEye = atan2f(cosf(yaw), sinf(yaw)), off: Float = 110 * .pi / 180, half: Float = 35 * .pi / 180
        return ((toEye + off, half), (toEye - off, half))
    }
    private var flankTurn = false
    private var lockSet = false
    /// swarmpack: runners only; swarmmix: every type.
    private var packType: BugType? { name == "swarmpack" ? .runner : nil }

    /// coach: time almost stops after a moment (the step on screen stays for the screenshot, the card's ghost thumb
    /// keeps moving: it runs on wall time); pressure: the hive pressure pinned inside the amber / red band.
    private func holdState(_ game: Game, _ dt: Float) {
        t += dt
        if name == "coach" {
            if !coachStepped && sinceReady >= 1.5 {
                coachStepped = true
                game.debugCoachStep(options.coachStep ?? (game.coach.step + 1))
                AppLog.info(String(format: "demo coach: step %d at td=%.2f", game.coach.step, sinceReady))
            }
            if freeze == 1 && coachStepped && sinceReady >= 2.5 {
                freeze = 0.02
                AppLog.info(String(format: "demo coach: frozen at t=%.1f step %d", game.time, game.coach.step))
            }
        } else {
            let g = game.difficulty.pressureGrace
            game.debugSetPressure(options.pressure == "amber" || sinceReady < 1.5 ? g - 7 : g + 5)
        }
    }

    /// store-shots.mjs (b), one step per frame so the scene drains (renders) the events of each step:
    /// fast(12) → tp(0, -5) → left stick (+50, -20) px for 1.5 s → 1.5 s idle → spawn(600, under the live cap) → right stick (-40, -45) px,
    /// firing, for 1.6 s → time ×0.02 (the web harness renders the shot at timeScale 0.05 for 4 frames).
    private func swarmShot(_ game: Game) {
        let r = Float(InputController.stickRadius)
        let aimDir = Game.worldFromScreen(-40 / (40 * 40 + 45 * 45).squareRoot(), -45 / (40 * 40 + 45 * 45).squareRoot())
        let aim = Game.angle(of: aimDir)
        switch shotStage {
        case 0:
            game.fastForward(seconds: 12)
            game.debugTeleport(0, -5)
            game.setPlayerInput(move: Game.worldFromScreen(50 / r, -20 / r), aim: nil, fire: false, ability: false, dash: false)
            game.fastForward(seconds: 1.5)
            game.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
            game.fastForward(seconds: 1.5)
            shotStage = 1
        case 1:
            let n = game.debugSpawn(crowd(600), type: nil, minRadius: 6, maxRadius: 26)
            game.setPlayerInput(move: Vec2(0, 0), aim: aim, fire: true, ability: false, dash: false, assist: 0.75)
            game.fastForward(seconds: 1.6)
            freeze = 0.02
            shotStage = 2
            AppLog.info("demo swarmshot: spawned \(n), alive \(game.bugsAlive), kills \(game.kills), player at (\(game.player.x), \(game.player.z))")
        default:
            // keep the trigger down (the scene sets the empty touch command before this every frame)
            game.setPlayerInput(move: Vec2(0, 0), aim: aim, fire: true, ability: false, dash: false, assist: 0.75)
        }
    }

    /// `-<key> <number>` among the launch options the parser did not know (demo staging only), else `fallback`.
    private func demoNum(_ key: String, _ fallback: Double) -> Double {
        let u = options.unknown
        guard let i = u.firstIndex(of: key), i + 1 < u.count, let v = Double(u[i + 1]) else { return fallback }
        return v
    }

    /// waves: the defence of the beacon the squad stands in, as the game plays it — charged to 27 % once it starts (the
    /// hive's first push at 30 % lands inside the window), time almost frozen at `-waveFreeze` s for the screenshot.
    private func waves(_ game: Game, _ dt: Float) {
        t += dt
        if !charged && game.activeBeacon >= 0 {
            charged = true
            game.debugBeaconProgress(0.27)
            AppLog.info(String(format: "demo waves: defence of beacon %d, charged to 0.27 td=%.2f alive %d", game.activeBeacon, sinceReady, game.bugsAlive))
        }
        logT -= dt
        if logT <= 0 {
            logT = 1
            let P = game.player
            let near = game.bugsNear(P.x, P.z, 16)
            AppLog.info(String(format: "demo waves: td=%.1f alive %d near16 %d pushes %d stage %d", sinceReady, game.bugsAlive, near,
                               game.beaconPushesFired, game.stage.rawValue))
        }
        if freeze == 1 && sinceReady >= demoNum("-waveFreeze", 6.5) {
            freeze = 0.02
            AppLog.info(String(format: "demo waves: frozen td=%.2f alive %d pushes %d", sinceReady, game.bugsAlive, game.beaconPushesFired))
        }
    }
    private var charged = false

    // ---------------------------------------------------------------- Stage 1 R2: the overhead
    private var ohStep = 0
    private var walkLogged = false, walkDone = false
    /// overhead: the packs up the riser and out of the duct mouth, the bots' fire, the freeze on a telegraph, the heartbeat.
    private func overhead(_ game: Game, _ dt: Float) {
        t += dt
        // (OverheadShowcase keeps R2's slice indices: node 2 the abyss riser, 4 the duct mouth)
        if ohStep == 0 && sinceReady >= 1.0 {
            ohStep = 1
            AppLog.info(String(format: "demo overhead: a pack of %d up the riser td=%.2f", game.debugRoutePack(6, entry: 2, rate: 3), sinceReady))
        }
        if ohStep == 1 && sinceReady >= 4.0 {
            ohStep = 2
            AppLog.info(String(format: "demo overhead: %d out of the duct mouth td=%.2f", game.debugRoutePack(5, entry: 4, rate: 2.5), sinceReady))
        }
        if ohStep == 2 && sinceReady >= 6.0 {
            ohStep = 3
            game.debugHoldFire = false
            AppLog.info(String(format: "demo overhead: the squad opens fire td=%.2f", sinceReady))
        }
        if walk {
            // the parallax walk: along the bridge's near half toward the hub, then idle (no freeze: the camera keeps moving)
            if sinceReady >= 1.0 && game.player.x > 1.5 {
                game.setPlayerInput(move: Vec2(-1, 0), aim: nil, fire: false, ability: false, dash: false)
                if !walkLogged { walkLogged = true; AppLog.info(String(format: "demo overhead: walking td=%.2f from x=%.1f", sinceReady, game.player.x)) }
            } else if walkLogged && !walkDone {
                walkDone = true
                AppLog.info(String(format: "demo overhead: walk done td=%.2f at (%.1f, %.1f)", sinceReady, game.player.x, game.player.z))
            }
        } else if freeze == 1 && sinceReady >= 7.0 && (game.dropZones.contains { $0.active && $0.progress > 0.3 } || sinceReady >= 9.0) {
            freeze = 0.02
            AppLog.info(String(format: "demo overhead: frozen td=%.2f up %d zones %d drops %d", sinceReady, game.routeAlive, game.activeDropZones,
                               game.overheadStats.drops))
        }
        logT -= dt
        if logT <= 0 {
            logT = 1
            let c = game.overheadStateCounts, s = game.overheadStats
            AppLog.info(String(format: "hb route alive=%d up=%d states=%d/%d/%d/%d/%d drops=%d landed=%d hits=%d kills=%d knock=%d zones=%d td=%.1f",
                               game.bugsAlive, game.routeAlive, c[0], c[1], c[2], c[3], c[4], s.drops, s.landed, s.hits, s.kills, s.knockdowns,
                               game.activeDropZones, sinceReady))
        }
    }

    // ---------------------------------------------------------------- Stage 1 R4: the overhead's bugs
    private var obStep = 0
    private var obPinA = false, obPinB: Float = -1, obShooting = false, obFreed: Float = -1, obSim0: Float = -1
    private var obBSent = false, obDashed = false

    /// overheadbugs: the overhead's own bugs (Stage 1 R4) on the showcase, on the sim clock (`ts`: sim seconds since «scene
    /// ready» — the log gives td too, so bursts can be placed): a Dropper out of the duct mouth drops on the
    /// player and pins it, the squad shoots it off; a spitter perches over the void on the far arm and spits; a pack is
    /// called to the duct, it rattles and the player shoots it shut; a second Dropper climbs the riser and pins the player
    /// again — frozen for the screenshot (the hint «Pinned — dash!») or, with -obDash, the dash out of it.
    private func overheadBugs(_ game: Game, _ dt: Float) {
        t += dt
        // (the sim clock starts with «scene ready», like the bursts' clock)
        if obSim0 < 0 { if sinceReady < 0 { return }; obSim0 = game.simTime }
        let ts = game.simTime - obSim0
        let dash = options.unknown.contains("-obDash")
        let P = game.player
        if obStep == 0 && ts >= 0.3 {
            obStep = 1
            AppLog.info(String(format: "demo overheadbugs: a Dropper to the duct mouth (%d) ts=%.2f td=%.2f",
                               game.debugRoutePack(1, entry: 4, rate: 3, type: .dropper), ts, sinceReady))
        }
        if obStep == 1 && ts >= 1.0 {
            obStep = 2
            AppLog.info(String(format: "demo overheadbugs: a spitter up the pad's post (%d) ts=%.2f td=%.2f",
                               game.debugRoutePack(1, entry: 0, rate: 3, type: .spitter), ts, sinceReady))
        }
        // the first pin: the squad opens fire on the Dropper and shoots it off, then holds again
        if obStep == 2 && !obPinA && P.pinned {
            obPinA = true
            game.debugHoldFire = false
            AppLog.info(String(format: "demo overheadbugs: the player is pinned, the squad opens fire ts=%.2f td=%.2f", ts, sinceReady))
        }
        if obStep == 2 && ((obPinA && !P.pinned) || ts >= 6.5) {
            obStep = 3
            obFreed = ts
            game.debugHoldFire = true
            AppLog.info(String(format: "demo overheadbugs: freed, the squad holds its fire again ts=%.2f td=%.2f", ts, sinceReady))
        }
        if obStep == 3 && ts >= max(5.4, obFreed + 0.5) {
            obStep = 4
            AppLog.info(String(format: "demo overheadbugs: a pack to the duct mouth (%d) ts=%.2f td=%.2f",
                               game.debugRoutePack(4, entry: 4, rate: 2), ts, sinceReady))
        }
        if obStep >= 4 && !obBSent && ts >= 6.0 {
            obBSent = true
            AppLog.info(String(format: "demo overheadbugs: a second Dropper up the riser (%d) ts=%.2f td=%.2f",
                               game.debugRoutePack(1, entry: 2, rate: 3, type: .dropper), ts, sinceReady))
        }
        // the player shoots the rattling duct shut: the stick toward the mouth where it is drawn, the assist turns the rounds up
        if obStep == 4 && ts >= 6.2, let d = game.ducts.first {
            if d.open && ts < 8.5 {
                let lift = 0.75 * max(0, d.pos.y - game.level.groundY(d.pos.x, d.pos.z))
                let aim = Game.angle(of: Vec2(d.pos.x + FWD_X * lift - P.x, d.pos.z + FWD_Z * lift - P.z))
                game.setPlayerInput(move: Vec2(0, 0), aim: aim, fire: true, ability: false, dash: false, assist: 0.75)
                if !obShooting { obShooting = true; AppLog.info(String(format: "demo overheadbugs: the player fires at the duct ts=%.2f td=%.2f", ts, sinceReady)) }
            } else {
                obStep = 5
                game.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
                AppLog.info(String(format: "demo overheadbugs: the player stops firing (duct %@) ts=%.2f td=%.2f", d.open ? "open" : "shut", ts, sinceReady))
            }
        }
        // the second pin: frozen for the screenshot — or the dash out of it
        if obBSent && obPinB < 0 && P.pinned {
            obPinB = ts
            AppLog.info(String(format: "demo overheadbugs: pinned again ts=%.2f td=%.2f", ts, sinceReady))
        }
        if obPinB >= 0 {
            if dash {
                if !obDashed && ts >= obPinB + 0.45 {
                    obDashed = true
                    game.setPlayerInput(move: Vec2(1, 0), aim: nil, fire: false, ability: false, dash: true)
                    AppLog.info(String(format: "demo overheadbugs: the player dashes out ts=%.2f td=%.2f", ts, sinceReady))
                } else if obDashed {
                    game.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
                }
            } else if freeze == 1 && ts >= obPinB + 0.25 {
                freeze = 0.02
                AppLog.info(String(format: "demo overheadbugs: frozen ts=%.2f td=%.2f pinned=%d hint=%@", ts, sinceReady, P.pinned ? 1 : 0,
                                   game.contextHint?.text.id.rawValue ?? "-"))
            }
        }
        logT -= dt
        if logT <= 0 {
            logT = 1
            let s = game.overheadStats, c = game.overheadStateCounts
            let ducts = game.ducts.map { d in d.open ? (d.rattleT > 0 ? "rattle" : "open") : String(format: "shut%.0f", d.shutT) }.joined(separator: ",")
            AppLog.info(String(format: "hb bugs droppers=%d up=%d pins=%d dash=%d fire=%d timeout=%d perched=%d spits=%d seals=%d states=%d/%d/%d/%d ducts=",
                               game.droppersAlive, game.routeAlive, s.pins, s.pinDash, s.pinFire, s.pinTimeout, c[6], s.perchSpits, s.seals,
                               c[0], c[2], c[5], c[6]) + ducts + String(format: " ts=%.1f td=%.1f", ts, sinceReady))
        }
    }

    // ---------------------------------------------------------------- Stage 1 R6: the interactive props
    private var ixStep = 0
    private var ixCool = 0
    private var ixArrived = false
    /// `-ixLights`: the lights part only, 7 s earlier.
    private var ixLightsOnly: Bool { options.unknown.contains("-ixLights") }
    /// interactives: the pack along the bridge valve's span, the valve popped (by the gunner, else by the demo once 6+ bugs
    /// are under it from 1.0 s, at the latest at 1.8 s), the
    /// hub's lights cut at 8.0 s, the player walking into the hub breaker's ring from 8.5 s, the lights coming back.
    private func interactives(_ game: Game, _ dt: Float) {
        t += dt
        if ixStep == 0 && ixLightsOnly { ixStep = 2 }
        let lightsAt: Double = ixLightsOnly ? 1.0 : 8.0
        if ixStep == 0 && sinceReady >= 0.8 {
            ixStep = 1
            let n = game.debugSpawnLine(12, type: .runner, from: Vec2(18.4, 27.7), to: Vec2(20.8, 29.5))
            AppLog.info(String(format: "demo interactives: a pack of %d under the valve's span td=%.2f", n, sinceReady))
        }
        if ixStep == 1, let v = game.valves.first {
            if v.phase != .ready {
                ixStep = 2
                AppLog.info(String(format: "demo interactives: the squad popped the valve (marine %d) td=%.2f", v.src, sinceReady))
            } else if (sinceReady >= 1.0 && v.crowd >= VALVE_BOT_CROWD) || sinceReady >= 1.8 {
                // the bots' own rule (6+ bugs under the span), the pack still on the bridge: the curtain catches it
                ixStep = 2
                game.debugBurstValve(0, by: 3)
                AppLog.info(String(format: "demo interactives: the demo popped the valve td=%.2f (%d bugs under it)", sinceReady, v.crowd))
            }
        }
        // the coolant line on the hub's west rail (valve 4 of the demo's set): a pack under it at 3.0 s, popped at 3.6 s
        let cool = game.valves.firstIndex { $0.site.kind == .coolant }
        if !ixLightsOnly, let c = cool {
            if ixCool == 0 && sinceReady >= 3.0 {
                ixCool = 1
                let s = game.valves[c].site
                let ux = s.bx - s.ax, uz = s.bz - s.az, ul = max(0.01, (ux * ux + uz * uz).squareRoot())
                let n = game.debugSpawnLine(8, type: .runner, from: Vec2(s.ax + ux / ul * 0.5, s.az + uz / ul * 0.5),
                                            to: Vec2(s.bx - ux / ul * 0.5, s.bz - uz / ul * 0.5))
                AppLog.info(String(format: "demo interactives: a pack of %d under the coolant line td=%.2f", n, sinceReady))
            }
            if ixCool == 1 && (game.valves[c].phase != .ready || sinceReady >= 3.6) {
                ixCool = 2
                if game.valves[c].phase == .ready { game.debugBurstValve(c, by: 3) }
                AppLog.info(String(format: "demo interactives: the coolant line burst (marine %d) td=%.2f", game.valves[c].src, sinceReady))
            }
        }
        if ixStep == 2 && sinceReady >= lightsAt && game.circuits.count > 1 {
            ixStep = 3
            game.debugCutCircuit(1)
            AppLog.info(String(format: "demo interactives: the hub's lights cut td=%.2f", sinceReady))
        }
        if ixStep == 3 && sinceReady >= lightsAt + 0.5 {
            // the player into the hub breaker's ring (1.1 m from the pedestal, on its side), then still
            let s = game.circuits[1].site, P = game.player
            var dx = P.x - s.x, dz = P.z - s.z
            let dl = max(0.01, (dx * dx + dz * dz).squareRoot())
            dx /= dl; dz /= dl
            let gx = s.x + dx * 1.1 - P.x, gz = s.z + dz * 1.1 - P.z, gl = (gx * gx + gz * gz).squareRoot()
            if gl > 0.25 && !ixArrived {
                game.setPlayerInput(move: Vec2(gx / gl, gz / gl), aim: nil, fire: false, ability: false, dash: false)
            } else {
                game.setPlayerInput(move: Vec2(0, 0), aim: nil, fire: false, ability: false, dash: false)
                if !ixArrived {
                    ixArrived = true
                    AppLog.info(String(format: "demo interactives: the player in the breaker's ring td=%.2f (progress %.2f)", sinceReady,
                                       game.circuits[1].progress))
                }
            }
            if game.circuits[1].powered {
                ixStep = 4
                AppLog.info(String(format: "demo interactives: the hub's lights back td=%.2f", sinceReady))
            }
        }
        logT -= dt
        if logT <= 0 {
            logT = 1
            let v = game.valves.first
            AppLog.info(String(format: "demo interactives: td=%.1f step %d alive %d valve %d (%.1f s) hub %d/%d ring %.2f lit %d/%d", sinceReady,
                               ixStep, game.bugsAlive, v?.phase.rawValue ?? -1, v?.t ?? 0, game.circuits.count > 1 ? game.circuits[1].burning : 0,
                               game.circuits.count > 1 ? game.circuits[1].lamps.count : 0, game.circuits.count > 1 ? game.circuits[1].progress : 0,
                               game.lightsLit, game.circuits.count))
        }
    }

    // ---------------------------------------------------------------- R7 missions
    private var msStep = 0
    private var msAt: Double = -1
    private var msLogT: Float = 0
    /// M1: when the squad got to work / the ring was jumped (or the mouth reopened), and whether the squad was put back in.
    private var msGo: Double = -1
    private var msJump: Double = -1
    private var msPut = 0
    /// breakerrun: the squad starts in the hub breaker's ring and fights the hive's surge there; from 6 s after «scene ready»
    /// the ring is held at 0.99 (quietly; the squad put into it again after 2.5 s if it is not thrown yet), time almost stopped
    /// 1.6 s after the throw (at 15.5 s at the latest).
    private func breakerRun(_ game: Game, _ dt: Float) {
        t += dt
        if msStep == 0 && sinceReady >= 6 && game.activeSwitch >= 0 {
            msStep = 1
            msJump = sinceReady
            AppLog.info(String(format: "demo breakerrun: the breaker's ring jumped to 0.99 td=%.2f (switch %d)", sinceReady, game.activeSwitch))
        }
        if msStep == 1 && game.switchesThrown == 0 && game.activeSwitch >= 0 {
            // keep the jump: the next moment anyone stands in the ring throws it
            if game.switches[game.activeSwitch].progress < 0.99 { game.debugSwitchProgress(0.99, quiet: true) }
            if msPut == 0 && sinceReady >= msJump + 2.5 {
                let s = game.switches[game.activeSwitch].site
                msPut = 1
                game.debugTeleport(s.x + 1.1, s.z)
                AppLog.info(String(format: "demo breakerrun: the squad put into the ring again td=%.2f", sinceReady))
            }
        }
        if msStep == 1 && game.switchesThrown > 0 {
            msStep = 2
            msAt = sinceReady
            AppLog.info(String(format: "demo breakerrun: breaker thrown td=%.2f, lit %d/%d", sinceReady, game.lightsLit, game.circuits.count))
        }
        if freeze == 1 && ((msStep == 2 && sinceReady >= msAt + 1.6) || sinceReady >= 15.5) {
            freeze = 0.02
            AppLog.info(String(format: "demo breakerrun: frozen td=%.2f step %d lit %d/%d alive %d obj %@", sinceReady, msStep, game.lightsLit,
                               game.circuits.count, game.bugsAlive, game.objective.map { "\($0)" } ?? "-"))
        }
        missionLog(game, dt)
    }

    /// ventpurge (M1: the duct held shut): the squad starts in the seal ring under the hub → A duct mouth; from «scene ready»
    /// on (the sim runs under the loading cover: nothing is staged before it) — the weld waits for the grille shot shut, the
    /// player shoots it (the demo does 3 s after «scene ready» if not) and the weld fills; at 6 s (1.5 s after the shut at the
    /// earliest) the weld is jumped to 0.6 and held there (quietly) and the hive chews through the grille early; time almost
    /// stops 0.3 s after the mouth opens again, the weld waiting once more (15.5 s at the latest).
    private func ventPurge(_ game: Game, _ dt: Float) {
        t += dt
        let k = game.activeSwitch
        let d = k >= 0 && k < game.switches.count ? game.switches[k].site.duct : -1
        let shut = d >= 0 && d < game.ducts.count && !game.ducts[d].open
        if msStep == 0 && k >= 0 && sinceReady >= 0.5 {
            msStep = 1
            msGo = sinceReady
            AppLog.info(String(format: "demo ventpurge: in the seal ring under duct %d td=%.2f, weld waits %d", d, sinceReady, game.weldWaits ? 1 : 0))
        }
        if msStep == 1 && !shut && d >= 0 && msPut == 0 && sinceReady >= msGo + 3 {
            msPut = 1
            _ = game.debugHurtDuct(d, DUCT_HP + 1)
            AppLog.info(String(format: "demo ventpurge: the demo shot duct %d shut td=%.2f (the player had not)", d, sinceReady))
        }
        if msStep == 1 && shut {
            msStep = 2
            msAt = sinceReady
            AppLog.info(String(format: "demo ventpurge: duct %d shot shut td=%.2f, the weld fills", d, sinceReady))
        }
        if msStep == 2 && sinceReady >= max(msAt + 1.5, 6) {
            msStep = 3
            game.debugSwitchProgress(0.6, quiet: true)
            if shut {
                game.debugReopenDuct(d)
                AppLog.info(String(format: "demo ventpurge: the weld jumped to 0.60, the hive chews through duct %d early td=%.2f (seal %d)", d, sinceReady, k))
            } else {
                AppLog.info(String(format: "demo ventpurge: the weld jumped to 0.60, duct %d already chewed through td=%.2f (seal %d)", d, sinceReady, k))
            }
        }
        if msStep >= 3 && k >= 0 && game.switchesThrown == 0 && game.switches[k].progress < 0.6 { game.debugSwitchProgress(0.6, quiet: true) }
        if msStep == 3 && d >= 0 && d < game.ducts.count && game.ducts[d].open {
            msStep = 4
            msJump = sinceReady
            AppLog.info(String(format: "demo ventpurge: duct %d open again td=%.2f, weld waits %d", d, sinceReady, game.weldWaits ? 1 : 0))
        }
        if freeze == 1 && ((msStep == 4 && sinceReady >= msJump + 0.3) || sinceReady >= 15.5) {
            freeze = 0.02
            AppLog.info(String(format: "demo ventpurge: frozen td=%.2f step %d weld waits %d ring %.2f alive %d obj %@", sinceReady, msStep,
                               game.weldWaits ? 1 : 0, k >= 0 && k < game.switches.count ? game.switches[k].progress : 0, game.bugsAlive,
                               game.objective.map { "\($0)" } ?? "-"))
        }
        missionLog(game, dt)
    }

    /// Once a second: `demo <name>: td=… step … switches … lit … vents shut … alive …`.
    private func missionLog(_ game: Game, _ dt: Float) {
        msLogT -= dt
        if msLogT > 0 { return }
        msLogT = 1
        AppLog.info(String(format: "demo %@: td=%.1f step %d mission step %d/%d %@ switches %d/%d ring %.2f lit %d/%d vents shut %d alive %d", name,
                           sinceReady, msStep, game.missionStep + 1, game.mission.steps.count, game.currentModule?.rawValue ?? "-",
                           game.switchesThrown, game.mission.switchCount, game.activeSwitch >= 0 ? game.switches[game.activeSwitch].progress : 0,
                           game.lightsLit, game.circuits.count, game.ventShut.filter { $0 }.count, game.bugsAlive))
    }

    // ---------------------------------------------------------------- WP7 cinematics
    /// punchin: the beacon comes on 1.5 s after «scene ready» (the punch-in plays out inside the measured window), at
    /// 4.6 s the shot plays again and holds 0.95 s in (past the dilation, at its peak), the world frozen ×0.02 from 5.3 s.
    private func punchIn(_ game: Game) {
        let c = Cinematics.shared
        switch cineStep {
        case 0 where sinceReady >= 1.5:
            cineStep = 1
            if game.stage == .beacons { game.debugSkip() }
            AppLog.info(String(format: "demo punchin: beacon on at td=%.2f (beacons done %d)", sinceReady, game.beaconsDone))
        case 1 where c.kind == .punchIn:
            cineStep = 2
            AppLog.info(String(format: "demo punchin: shot started td=%.2f", sinceReady))
        case 2 where sinceReady >= 4.6:
            cineStep = 3
            c.replayPunchIn()
            AppLog.info(String(format: "demo punchin: replay + hold td=%.2f", sinceReady))
        case 3 where sinceReady >= 5.55:
            cineStep = 4
            c.hold(at: 0.95)
            freeze = 0.02
            AppLog.info(String(format: "demo punchin: held at 0.95 s, world frozen td=%.2f", sinceReady))
        default: break
        }
    }

    /// extract-cine: the lift leaves 1.5 s after «scene ready» (begin() left the stage at hold), runs 2.8 s into its
    /// rise and is pinned there for the screenshot.
    private func extractCine(_ game: Game) {
        switch cineStep {
        case 0 where sinceReady >= 1.5:
            cineStep = 1
            if game.stage == .hold { game.debugSkip() }
            AppLog.info(String(format: "demo extract-cine: lift leaves td=%.2f stage %d", sinceReady, game.stage.rawValue))
        case 1 where game.stage == .extract && game.extractT >= 2.8:
            cineStep = 2
            AppLog.info(String(format: "demo extract-cine: pinned at %.2f s td=%.2f", game.extractT, sinceReady))
        default: break
        }
        if cineStep == 2 { game.debugPinExtract(2.8) }
    }
}
