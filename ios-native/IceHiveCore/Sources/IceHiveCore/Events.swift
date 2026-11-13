import Foundation

// ================================================================
//  EVENTS — everything the renderer / audio / haptics need to react to.
//  The simulation appends to `Game.events` during `tick()`; the app drains
//  them once per frame (`drainEvents`). Gameplay never reads them back.
//  Visual-only rules of the web game that depend on the player's position
//  (screen shake, hit-stop, white flash) are resolved here too, so the app
//  only plays what it is told.
// ================================================================

public enum ExplosionKind: Int {
    /// Assault frag grenade (big).
    case frag
    /// Cluster bomblet / explosive round (small).
    case mini
    /// Boomer death (big, hurts marines).
    case boomer
    /// Frozen bug shattering.
    case frost
    /// Lift defence shock pulse.
    case pulse

    public var isBig: Bool { self == .frag || self == .boomer }
}

public enum AbilityKind: Int {
    case grenade, napalm, nova, turret
}

/// Procedural sound recipes of 09-audio.js (names match the web `sfx()` ids).
public enum SoundID: String, CaseIterable {
    case pulse, mg, tur, reload, overheat, explode, pop, squish, shatter, freeze, hurt, down, revive, dash
    case throwGrenade = "throw"
    case napalm, shock, thud
    case kill, combo, hordeRoar, nova, turret, heal, spit, acid, roar, swell, siren, beacon, beaconDone, lift, levelup, click, heart, victory, defeat
    /// The Матка climbs onto the deck (v1.1; non-positional; her roar: `BossSpec.roar`).
    case queen
}

public enum HapticKind: Int {
    case select, light, medium, heavy, success, warning, error
}

public enum ToastKind: Int {
    case info, warn, gold
}

public enum GameEvent {
    // --- swarm ---
    /// A bug died. `source`: marine index 0..3, -1 = environment (explosions without owner, lift pulse).
    case bugKilled(type: BugType, pos: Vec2, frozen: Bool, source: Int, heading: Float, scale: Float, height: Float)
    /// A bug crossed the freeze threshold under the cryo beam.
    case bugFrozen(pos: Vec2)
    /// First sighting of a special bug type in this run.
    case bugSeen(type: BugType)
    /// Spitter launched an acid glob (flight time 0.95 s).
    case acidLaunched(from: Vec2, to: Vec2)
    /// Acid glob landed (splash radius 1.5).
    case acidSplash(pos: Vec2)
    case explosion(kind: ExplosionKind, pos: Vec2, radius: Float)

    // --- weapons ---
    /// A projectile hit a bug (dir = projectile direction).
    case bulletHit(pos: Vec2, dir: Vec2, killed: Bool)
    /// A marine fired a projectile weapon round (muzzle flash).
    case muzzle(marine: Int)
    case turretShot(pos: Vec2, angle: Float)
    case reload(marine: Int)
    case overheat(marine: Int)

    // --- marines ---
    case hurt(marine: Int, amount: Float)
    case downed(marine: Int)
    case revived(marine: Int)
    case dash(marine: Int, dir: Vec2)
    case ability(marine: Int, kind: AbilityKind, pos: Vec2, radius: Float)
    case turretExpired(pos: Vec2)
    case grenadeThrown(from: Vec2, to: Vec2, big: Bool)
    case medkitDropped(pos: Vec2)
    case healed(marine: Int, amount: Float, pos: Vec2)

    // --- telegraphs (also kept in `Game.telegraphs` with their lifetime; draw from the pool,
    //     the index may be reused once that telegraph has expired) ---
    case telegraph(index: Int, shape: TelegraphShape, cause: TelegraphCause, pos: Vec2)

    // --- mission flow ---
    case hordeStarted(size: Int, title: GameText, subtitle: GameText)
    case beaconStarted(index: Int)
    case beaconCompleted(index: Int)
    case liftCalled
    case holdStarted
    case extractStarted
    /// The mission plan moved on to step `index` (Mission.swift; never for its first step).
    case missionStep(index: Int, module: MissionModule)
    /// A switch of a SWITCH step started / was thrown (`Game.switches[index]`; R6's props listen).
    case switchStarted(index: Int)
    case switchThrown(index: Int)
    /// R7 (Vent Purge): the station's vent `index` (`LevelLayout.vents`) was sealed for good; a pack pours out of an open
    /// seal's vent `index`.
    case ventSealed(index: Int)
    case ventPour(index: Int, count: Int)
    case levelUp(level: Int)
    case combo(count: Int)
    case victory
    case defeat

    // --- the bosses (Stage 2 B1, GameBoss.swift; v1.1's Матка is the first) ---
    /// Its warning: the red ring (`BossSpec.warn` s, the Queen's 2 s) where it will come (the Queen: over the lift rim).
    case bossWarning(kind: BossKind, pos: Vec2)
    /// It is there (banner, siren + its roar, shake and haptic come as their own events).
    case bossSpawned(kind: BossKind, pos: Vec2)
    /// It entered phase `phase` (below its health threshold; the Queen's 1: enraged — faster, and the hive answers).
    case bossPhase(kind: BossKind, phase: Int, enraged: Bool, pos: Vec2)
    /// It died (emitted before its `.hitStop`: the app resets its hit-stop cooldown so this one always plays).
    case bossKilled(kind: BossKind, pos: Vec2)
    /// A telegraphed move's wind-up starts (`move`: its index in the spec's moves; its telegraph comes as `.telegraph`).
    case bossMove(kind: BossKind, move: Int, pos: Vec2)
    /// A weak-point window opens on part `part` for `time` s (the head down: its damage × its `downK`).
    case bossWindow(kind: BossKind, part: Int, pos: Vec2, time: Float)
    /// Part `part`'s own pool is spent (a node popped: dark, the boss staggers).
    case bossPartPopped(kind: BossKind, part: Int, pos: Vec2)
    /// Part `part` froze (a boss that is not freeze-immune: its body locks instead).
    case bossPartFrozen(kind: BossKind, part: Int, pos: Vec2)
    /// Stage 2 B4: a moment of a boss's own moves for the renderer, the audio and the logs (`BossCue`; `value`: the marine,
    /// the trunk, the burst, the part or a count — see each cue).
    case bossCue(kind: BossKind, cue: BossCue, pos: Vec2, value: Int)

    // --- v1.1 «Ставки»: the first-run coach ---

    // --- Stage 1 R2: the overhead ---
    /// A bug up on a route committed to a drop: from its place (x, absolute y, z) onto the deck point `to`, landing in
    /// `eta` s (its closing ring is the telegraph `.dropZone`; `Game.dropZones` holds the same warning).
    case dropWarned(from: SIMD3<Float>, to: Vec2, eta: Float)
    /// The drop landed; `hit`: a marine stood inside the ring.
    case dropLanded(pos: Vec2, hit: Bool)
    /// A bug was knocked off a route (fire, frost, a blast) and falls from `height` m above the deck under it.
    case routeKnockdown(pos: Vec2, height: Float)

    // --- Stage 1 R4: the overhead's bugs (GameOverheadBugs.swift) ---
    /// A Dropper landed on marine `marine` and pins it for `time` s at most (the Dropper holds on at `pos`).
    case pinned(marine: Int, pos: Vec2, time: Float)
    /// The pin on marine `marine` ended (`cause`; `freer`: the marine whose fire got it off, -1 none) — the Dropper at `pos`.
    case pinBroken(marine: Int, pos: Vec2, cause: PinBreak, freer: Int)
    /// Duct mouth `index` (`Game.ducts`) rattles: a pack pours out of it in DUCT_RATTLE s.
    case ductRattle(index: Int)
    /// A round or a blast struck duct mouth `index`'s grille.
    case ductHit(index: Int)
    /// Duct mouth `index` was shot shut (DUCT_SHUT s) / the hive chewed through it again.
    case ductSealed(index: Int)
    case ductOpened(index: Int)
    /// A spitter took a perch at (x, absolute y, z).
    case perched(pos: SIMD3<Float>)
    /// A perched spitter's glob: from (x, absolute y, z) onto the deck point `to`, landing in `flight` s (its lime ring and
    /// fill are the usual `.acidTarget` telegraphs).
    case acidFromPerch(from: SIMD3<Float>, to: Vec2, flight: Float)
    // --- Stage 1 R6: interactive props (`Game.valves` / `circuits` / `lamps` / `lockers` hold the state) ---
    /// A round struck steam valve `index` on its pipe.
    case valveHit(index: Int)
    /// Valve `index` bursts: VALVE_WARN s of warning, then its scald curtain.
    case valveBurst(index: Int)
    /// Its scald curtain stands under the span (VALVE_VENT s).
    case valveVented(index: Int)
    /// It holds pressure again: ready to be shot (the amber gauge).
    case valveReady(index: Int)
    /// The hive broke lamp `index` (acid, a brute, a blast).
    case lampBroken(index: Int)
    /// Light circuit `index` is back on: every lamp of it whole and burning (a breaker ring or a breaker switch).
    case circuitRestored(index: Int)
    /// Light circuit `index` lost its power (a darkness event).
    case circuitCut(index: Int)
    /// Supply locker `index` opened by marine `marine` (its medkit is out, its ability ready).
    case lockerOpened(index: Int, marine: Int)
    /// The coach moved to step `index` (0…4).
    case coachStep(index: Int)
    /// The coach was seen far enough (end of step 4, skip, early end): the app stores `tut = 1`. Once per Game.
    case coachSeen
    /// The coach finished (any way).
    case coachEnded

    // --- presentation ---
    case toast(text: GameText, kind: ToastKind)
    /// Big centred banner (teal = good news, otherwise red/amber).
    case banner(title: GameText, subtitle: GameText, teal: Bool)
    /// Play a sound; pos nil = non-positional. `loud` is the web sfx() 4th argument: nil = not given (full volume),
    /// true = the player's own weapon / ability, false = a bot's (played at half volume).
    case sound(SoundID, pos: Vec2?, loud: Bool?)
    case haptic(HapticKind)
    /// Add camera shake (web addShake amount, before reduced-motion scaling).
    case shake(amount: Float)
    /// Slow the world for `duration` s by factor `scale` (the app applies its own cooldown, 0.8 s + duration).
    case hitStop(duration: Float, scale: Float)
    /// White screen flash (0..1).
    case screenFlash(amount: Float)
    /// Red damage vignette increase for the player (0..1).
    case damageFlash(amount: Float)
    /// Red edge flash of a starting horde.
    case hordeFlash
}

// ================================================================
//  TELEGRAPHS — floor warnings / ability rings with a lifetime
//  (TELE pool of 07-fx.js: teleRing / teleLane / teleFill).
// ================================================================
/// How a Dropper's pin ended (`GameEvent.pinBroken`, Stage 1 R4): the pinned marine's dash, the squad's fire (15 damage on
/// the Dropper, killing or freezing it), the pin running out, the marine going down, anything else (the extraction).
public enum PinBreak: Int {
    case dash, fire, timeout, down, release
}

/// Stage 2 B4: a moment of a boss's own moves (`GameEvent.bossCue`) — the Threader's (GameThreader.swift). `value` in
/// brackets.
public enum BossCue: Int {
    /// The lure locked on a marine [marine]: the beam turns hot white, the strike's closing ring is at `pos`.
    case lureLock
    /// The head lets go of its trunk and drops onto the ring; it lands [marines in the slam]; it lands in the Pyro's fire and
    /// recoils (+1 s down).
    case strikeDrop, strikeLand, recoil
    /// It climbs a riser pipe to the ring duct; it is up there (untouchable); it comes back down onto a trunk.
    case climb, duct, descend
    /// The coil starts round a marine [marine]; it crushes; it lets go (a grenade on a node, a pop); two frozen segments open
    /// a gap [the segment].
    case coil, coilCrush, coilLetGo, coilGap
    /// Rime spit along a trunk [trunk].
    case rimeSpit
    /// It crushes a trunk [trunk]; a valve of it starts its warning (the gauge needle, the hiss) [burst]; it vents [burst].
    case squeeze, squeezeBurst, squeezeVent
    /// It rips a trunk [trunk] (its red lane and dust); the trunk crashes across the deck [trunk]; the body comes down.
    case pullRip, pullCrash, deckDrop
    /// A charge on the deck after a marine [marine] (the beam along its path).
    case charge
    /// Frost dust falls along the body (the shed's warning); the ticks drop [count].
    case shed, ticks
    /// The torch stripped a node's frost plates [part]; a node popped: it screams [part].
    case plateStrip, scream
    /// A duct mouth pours a pack [duct].
    case packs
    /// It took THREADER_WINDOW_CAP of its health in one exposure — a punish window and the way back up [0: the head pulls
    /// back up at once] or a coil [1: it lets go] — a scream; the ice on it breaks.
    case pain
}

public enum TelegraphShape: Int {
    /// Ring from r0 to r1 over its life; `pulse` = blinking warning, otherwise an expanding shock ring.
    case ring
    /// Brute charge lane: pulses during `wind`, stays lit while the brute charges.
    case lane
    /// Disc that fills up as the impact approaches (acid globs).
    case fill
    // ---- Stage 2 B1: the boss framework's shapes (cause `.bossMove`; drawn by the boss's renderer)
    /// A cone from (x, z) along (dx, dz): `len` long, half-angle `w` (rad) — a sweep turns it while it is lit.
    case cone
    /// A thin line from (x, z) along (dx, dz), `len` long and `w` wide: pulses during `wind`, lit while it acts.
    case beam
    /// A drop target: a ring closing r0 → r1 at (x, z) over its life (something lands there).
    case drop
}

public enum TelegraphCause: Int {
    case acidTarget, bruteLane, boomerSwell, napalm, nova, pulse, other
    /// Where a boss will come (red, its warning: the Queen's rim, 2 s) / a boss's acid volley (one ring + fill per marine).
    case bossRim, bossVolley
    /// Stage 1 R2: something drops from the overhead HERE — a closing ring (DROP_RING0 → DROP_RING) for the whole warning,
    /// in the pink-white of the hive's pores (the telegraph lexicon's «lands here», design §1.1.4).
    case dropZone
    /// Stage 1 R6: a steam valve bursts — its amber ring («it explodes»: the lexicon's valve about to burst) and the strip
    /// of its scald curtain on the deck (a steam-white lane: pulsing through the warning, fading over the curtain).
    case steam
    /// Stage 2 B1: a boss's telegraphed move (any shape; its colour from the move).
    case bossMove
}

public struct Telegraph {
    public internal(set) var active: Bool = false
    public internal(set) var shape: TelegraphShape = .ring
    public internal(set) var cause: TelegraphCause = .other
    public internal(set) var x: Float = 0, z: Float = 0
    /// Lane direction (unit) and length / width.
    public internal(set) var dx: Float = 0, dz: Float = 0
    public internal(set) var len: Float = 1, w: Float = 1
    public internal(set) var r0: Float = 1, r1: Float = 1
    /// Colour (linear-ish 0..1 like the web instance colours).
    public internal(set) var r: Float = 1, g: Float = 1, b: Float = 1
    public internal(set) var t: Float = 0
    public internal(set) var life: Float = 1
    public internal(set) var wind: Float = 0
    public internal(set) var pulse: Bool = true

    /// 0..1 progress over the lifetime.
    public var progress: Float { life > 0 ? min(1, t / life) : 1 }
    /// Current ring radius (r0 -> r1).
    public var radius: Float { r0 + (r1 - r0) * progress }
}

let TELE_POOL = 64 + 16 + 32
