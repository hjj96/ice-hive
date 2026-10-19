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
    /// The Матка climbs onto the deck (v1.1; non-positional).
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
    case hordeStarted(size: Int, title: String, subtitle: String)
    case beaconStarted(index: Int)
    case beaconCompleted(index: Int)
    case liftCalled
    case holdStarted
    case extractStarted
    case levelUp(level: Int)
    case combo(count: Int)
    case victory
    case defeat

    // --- v1.1 «Ставки»: the Матка and the first-run coach ---
    /// 2 s red ring where the Матка will climb over the lift rim.
    case queenWarning(pos: Vec2)
    /// She is on the deck (banner, siren + queen sound, shake and haptic come as their own events).
    case queenSpawned(pos: Vec2)
    /// Below half health once: faster, and the hive answers with a horde.
    case queenEnraged(pos: Vec2)
    /// She died (emitted before its `.hitStop`: the app resets its hit-stop cooldown so this one always plays).
    case queenKilled(pos: Vec2)
    /// The coach moved to step `index` (0…4).
    case coachStep(index: Int)
    /// The coach was seen far enough (end of step 4, skip, early end): the app stores `tut = 1`. Once per Game.
    case coachSeen
    /// The coach finished (any way).
    case coachEnded

    // --- presentation ---
    case toast(text: String, kind: ToastKind)
    /// Big centred banner (teal = good news, otherwise red/amber).
    case banner(title: String, subtitle: String, teal: Bool)
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
public enum TelegraphShape: Int {
    /// Ring from r0 to r1 over its life; `pulse` = blinking warning, otherwise an expanding shock ring.
    case ring
    /// Brute charge lane: pulses during `wind`, stays lit while the brute charges.
    case lane
    /// Disc that fills up as the impact approaches (acid globs).
    case fill
}

public enum TelegraphCause: Int {
    case acidTarget, bruteLane, boomerSwell, napalm, nova, pulse, other
    /// v1.1: where the Матка will climb up (red, 2 s) / her acid volley (one ring + fill per marine).
    case queenRim, queenVolley
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
