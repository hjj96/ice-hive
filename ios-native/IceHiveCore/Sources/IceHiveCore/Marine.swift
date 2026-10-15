import Foundation

// ================================================================
//  MARINE — player + AI squad state (port of makeMarine / baseMods, 06-marines.js)
// ================================================================

/// Multipliers changed by upgrades.
public struct Mods {
    public var dmg: Float = 1
    public var rof: Float = 1
    public var pierce: Int = 0
    /// Ability radius.
    public var arad: Float = 1
    /// Ability cooldown.
    public var acd: Float = 1
    public var speed: Float = 1
    public var regen: Float = 0
    public var dashCd: Float = 1
    public var range: Float = 1
    public var cone: Float = 1
    public var burn: Float = 1
    public var shatter: Float = 1
    public var chill: Float = 1
    public var turretDur: Float = 0
    public var turretRof: Float = 1
    public var heat: Float = 1
    public var cluster: Int = 0
    public var explosive: Int = 0

    init(bot: Bool, botDamage: Float) { dmg = bot ? botDamage : 1 }
}

/// Bot brain scratch state.
struct BotAI {
    var think: Float = 0
    var target: Int = -1
    var tuid: Int32 = 0
    var dodge: Float = 0
    var stuck: Float = 0
    var lx: Float = 0, lz: Float = 0
    var sideX: Float = 0, sideZ: Float = 0, sideT: Float = 0
}

public final class Marine {
    /// Squad slot 0..3 (0 = player).
    public let index: Int
    public let cls: MarineClass
    public let spec: ClassSpec
    public let name: String
    public let isPlayer: Bool
    public internal(set) var mods: Mods

    /// Position and the position at the start of the last tick (render interpolation).
    public internal(set) var x: Float = 0, z: Float = 0
    public internal(set) var px: Float = 0, pz: Float = 0
    public internal(set) var vx: Float = 0, vz: Float = 0
    /// Knockback velocity.
    public internal(set) var kx: Float = 0, kz: Float = 0
    /// Aim angle (direction = (sin, cos)) and its unit vector.
    public internal(set) var aim: Float = 0
    public internal(set) var ax: Float = 0, az: Float = 1
    /// Movement facing (bots' formation reference).
    public internal(set) var faceX: Float = FWD_X, faceZ: Float = FWD_Z

    public internal(set) var hp: Float = 100
    public internal(set) var maxHp: Float = 100
    public internal(set) var downed: Bool = false
    /// Revive progress 0..1 while downed.
    public internal(set) var revive: Float = 0
    /// Invulnerability timer, hurt flash timer.
    public internal(set) var inv: Float = 0
    public internal(set) var hurtT: Float = 0
    public internal(set) var dashT: Float = 0
    public internal(set) var dashCd: Float = 0
    public internal(set) var dashX: Float = 0, dashZ: Float = 0
    public internal(set) var abCd: Float = 0
    var fireCd: Float = 0
    /// Weapon heat 0..1 (gunner, pyro), overheat lockout timer.
    public internal(set) var heat: Float = 0
    public internal(set) var over: Float = 0
    /// Minigun spin 0..1.
    public internal(set) var spin: Float = 0
    /// Cryo energy 0..1.
    public internal(set) var energy: Float = 1
    public internal(set) var ammo: Int = 0
    public internal(set) var reload: Float = 0
    /// Nameplate bar: ammo / heat / energy (1 = full).
    public internal(set) var bar: Float = 1
    public internal(set) var firing: Bool = false
    /// Current cryo beam length.
    public internal(set) var beamLen: Float = 0
    /// Muzzle flash 1 -> 0.
    public internal(set) var muzzle: Float = 0
    /// Seconds since the last damage taken (passive regen).
    public internal(set) var calm: Float = 0
    /// Melee bite slots (small bugs need one each).
    var bite: Float = 3
    var ai = BotAI()

    init(index: Int, cls: MarineClass, name: String, isPlayer: Bool, botDamage: Float) {
        self.index = index
        self.cls = cls
        self.spec = cls.spec
        self.name = name
        self.isPlayer = isPlayer
        self.mods = Mods(bot: !isPlayer, botDamage: botDamage)
        self.ammo = cls.spec.mag
    }

    public var position: Vec2 { Vec2(x, z) }
    public var aimDir: Vec2 { Vec2(ax, az) }
    /// Ability cooldown fraction 1 -> 0 (0 = ready).
    public var abilityCooldownFraction: Float { abCd > 0 ? abCd / (spec.abCd * mods.acd) : 0 }
    /// Dash cooldown fraction 1 -> 0 (0 = ready).
    public var dashCooldownFraction: Float { dashCd > 0 ? dashCd / (3 * mods.dashCd) : 0 }
    public var abilityReady: Bool { abCd <= 0 && !downed }
    public var dashReady: Bool { dashCd <= 0 && !downed }
    /// Overheated / out of energy lockout.
    public var overheated: Bool { over > 0 }
    public var reloading: Bool { reload > 0 }
    /// Invulnerable after a revive (blink), not during a dash.
    public var invulnerable: Bool { inv > 0 && !downed && dashT <= 0 }
    public var dashing: Bool { dashT > 0 }
}
