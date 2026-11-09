import Foundation

// ================================================================
//  INTERACTIVE PROPS — the data (Stage 1 R6 «Valves, light, lockers»;
//  design.md §1.4, §1.1.5). What a station carries besides its decks, all
//  used without a new button — you stand in its ring or you shoot it:
//    STEAM VALVE    on a pipe above a deck; shot (60) it bursts — after a
//                   short warning a scald curtain stands under its span for
//                   5 s: deck bugs take 40/s, marines 10/s, the light bugs up
//                   on the span die, nothing drops through it; ready again
//                   25 s after it burst (its amber gauge)
//    LIGHT CIRCUIT  a breaker ring (6 s) and the deck lamps of its decks. Lit
//                   deck forbids drops from the overhead (design: «Operation
//                   Cold Light becomes literal»); the hive breaks lamps
//                   (spitters spit on them, brutes ram them),
//                   a breaker brings the whole circuit back, a lit beacon
//                   lights its deck for good; the report counts the circuits
//                   lit at extraction
//    COOLANT LINE   the cold variant of the valve (design §1.3 B): shot, a
//                   freezing mist under its span for 2 s — the bugs in it
//                   freeze (the ones up on the span fall and shatter)
//    SUPPLY LOCKER  a 2 s ring: one medkit and the opener's ability ready,
//                   once per mission
//  The lamps are the station's own lamp posts: WorldLevel puts one every
//  12 m along the railing runs and `StationLamps.place` is the same rule in
//  the core, so the lit mask and the drawn lamps agree. The runtime is
//  GameProps.swift. The classic «Кельвин-9» carries none (calibration
//  byte-identical) until a mission (R7) or package R5 lays `PropLayout.kelvin`.
// ================================================================

// ---------- the numbers (design §1.1.5, §1.4) ----------
/// A steam valve bursts after this much damage (rounds aimed up at it, the squad's blasts reaching up).
public let VALVE_HP: Float = 60
/// The burst's warning (s): the gauge spins red and the valve hisses before the curtain.
public let VALVE_WARN: Float = 0.35
/// The scald curtain (s).
public let VALVE_VENT: Float = 5
/// The recharge after the curtain (s): ready again 25 s after it burst.
public let VALVE_COOL: Float = 25 - VALVE_VENT - VALVE_WARN
/// A coolant line's freezing mist (s) and the chill it gives a bug in it per second (a bug freezes in ≈ 0.45 s).
public let COOLANT_MIST: Float = 2
public let COOLANT_CHILL: Float = 2.2
/// Rounds aimed up strike a valve whose footprint (its plan position) they pass within this radius (m; the valve body, its
/// wheel and flanges — a chunky target next to a bug's 0.35–0.6 m footprint).
public let VALVE_HIT_R: Float = 0.75
/// The curtain's damage per second: bugs on the deck under it, marines in it (design: 40 / 10).
public let CURTAIN_BUG_DPS: Float = 40
public let CURTAIN_MARINE_DPS: Float = 10
/// The bots pop a ready valve once this many deck bugs stand under its span (design: «6+ bugs under the span»).
public let VALVE_BOT_CROWD = 6
/// A lamp's health: one acid glob (LAMP_SPIT_DMG) or a brute ramming its post breaks it.
public let LAMP_HP: Float = 60
public let LAMP_SPIT_DMG: Float = 60
/// A burning lamp lights the deck within this radius of its light pool (m; lamps stand 12 m apart).
public let LAMP_LIT_R: Float = 5.5
/// A lit beacon is a big lamp: it lights its deck within this radius for good (m).
public let BEACON_LIT_R: Float = 9
/// The hive spits on a lamp at most once in this many seconds (design: «at most one lamp every 30 s»).
public let LAMP_SPIT_GAP: Float = 30
/// The breaker ring and the locker ring: radius (m) and seconds of standing in it (design: 6 s / 2 s).
public let BREAKER_R: Float = 2.0
public let BREAKER_TIME: Float = 6
public let LOCKER_R: Float = 1.6
public let LOCKER_TIME: Float = 2

// ---------- the sites ----------
/// What a valve vents: steam (the scald curtain) or coolant (a coolant line's freezing mist).
public enum ValveKind: UInt8 {
    case steam, coolant
}

/// A steam valve (or a coolant line's valve) on a pipe: the valve body (plan position + absolute height; rounds aimed up
/// strike its footprint) and the span its curtain stands under — a strip on the deck from a to b (plan), `width` m to
/// either side of it.
public struct ValveSite: Equatable {
    public var x: Float, y: Float, z: Float
    public var ax: Float, az: Float, bx: Float, bz: Float
    public var width: Float
    public var kind: ValveKind
    public init(x: Float, y: Float, z: Float, from a: Vec2, to b: Vec2, width: Float = 1.5, kind: ValveKind = .steam) {
        self.x = x; self.y = y; self.z = z
        ax = a.x; az = a.y; bx = b.x; bz = b.y
        self.width = width; self.kind = kind
    }
    /// Seconds its curtain stands (steam 5, coolant mist 2) and its recharge after it (ready 25 s after the burst).
    public var ventTime: Float { kind == .coolant ? COOLANT_MIST : VALVE_VENT }
    public var coolTime: Float { 25 - ventTime - VALVE_WARN }
    /// The curtain's centre on the deck.
    public var mid: Vec2 { Vec2((ax + bx) / 2, (az + bz) / 2) }
    /// Plan distance from (x, z) to the curtain's centre line.
    public func lineDistance(_ x: Float, _ z: Float) -> Float {
        let dx = bx - ax, dz = bz - az, l2 = dx * dx + dz * dz
        var u: Float = 0
        if l2 > 1e-6 { u = clampf(((x - ax) * dx + (z - az) * dz) / l2, 0, 1) }
        return hypotf2(x - (ax + dx * u), z - (az + dz * u))
    }
    /// Inside the curtain (plan), `pad` m wider.
    @inline(__always) public func covers(_ x: Float, _ z: Float, pad: Float = 0) -> Bool { lineDistance(x, z) <= width + pad }
    /// Up on the span (plan): within 1 m of the pipe the valve sits on — the curtain's centre line moved over to the valve.
    public func spanCovers(_ x: Float, _ z: Float) -> Bool {
        let dx = bx - ax, dz = bz - az, l2 = dx * dx + dz * dz
        var u: Float = 0
        if l2 > 1e-6 { u = clampf(((self.x - ax) * dx + (self.z - az) * dz) / l2, 0, 1) }
        let ox = self.x - (ax + dx * u), oz = self.z - (az + dz * u)
        return lineDistance(x - ox, z - oz) <= 1.0
    }
}

/// A light circuit: its breaker — a waist-high pedestal at (x, z) that blocks its cell, its ring round it like a beacon's
/// — and the decks it lights: the station lamps standing inside these rects (x0, z0, x1, z1; 0.5 m of slack round them)
/// are on it (the first circuit that claims a lamp keeps it).
public struct CircuitSite: Equatable {
    public var x: Float, z: Float
    public var radius: Float
    public var time: Float
    public var zones: [SIMD4<Float>]
    public init(x: Float, z: Float, zones: [SIMD4<Float>], radius: Float = BREAKER_R, time: Float = BREAKER_TIME) {
        self.x = x; self.z = z; self.zones = zones; self.radius = radius; self.time = time
    }
    /// The lamp post at (x, z) is on this circuit.
    public func claims(_ x: Float, _ z: Float) -> Bool {
        for r in zones where x > r.x - 0.5 && x < r.z + 0.5 && z > r.y - 0.5 && z < r.w + 0.5 { return true }
        return false
    }
}

/// A supply locker: where a marine stands to open it (its ring) and the way its door faces (yaw, aim convention: the
/// door looks along (sin yaw, cos yaw); the cabinet stands 0.9 m behind the ring's centre, against a rail, and blocks
/// its cell).
public struct LockerSite: Equatable {
    public var x: Float, z: Float
    public var yaw: Float
    public var radius: Float
    public var time: Float
    public init(x: Float, z: Float, yaw: Float, radius: Float = LOCKER_R, time: Float = LOCKER_TIME) {
        self.x = x; self.z = z; self.yaw = yaw; self.radius = radius; self.time = time
    }
    /// The cabinet (plan), against the rail behind the ring.
    public var cabinet: Vec2 { Vec2(x - sinf2(yaw) * 0.9, z - cosf2(yaw) * 0.9) }
}

/// Everything interactive a station carries (empty: none — the classic «Кельвин-9»).
public struct PropLayout: Equatable {
    public var valves: [ValveSite]
    public var circuits: [CircuitSite]
    public var lockers: [LockerSite]
    public init(valves: [ValveSite] = [], circuits: [CircuitSite] = [], lockers: [LockerSite] = []) {
        self.valves = valves; self.circuits = circuits; self.lockers = lockers
    }
    public var isEmpty: Bool { valves.isEmpty && circuits.isEmpty && lockers.isEmpty }

    /// «Кельвин-9» Mk II's interactives (design §1.2.1): seven light circuits — one per deck and the lift — with their
    /// breakers; steam valves on the Spine Rack over the pad → hub bridge (the overhead's demo slice: 4.5 m, the far rail
    /// at z 26.4), on the heat exchanger along beacon B's far rail (4 m over the −3 deck) and on the plaza gantry over the
    /// head of the stairs down to the lift (5 m); a supply locker on the hub. Missions lay it (R7: Breaker Run); the classic
    /// mission does not until package R5.
    public static let kelvin: PropLayout = {
        func r(_ x0: Float, _ z0: Float, _ x1: Float, _ z1: Float) -> SIMD4<Float> { SIMD4(x0, z0, x1, z1) }
        // (each breaker clear of the vents, the crates and its deck's beacon ring; lamps per circuit 3 / 6 / 7 / 10 / 8 / 10 / 4)
        let circuits = [
            // the landing pad (the squad starts here)
            CircuitSite(x: 33.5, z: 33.5, zones: [r(22, 22, 38, 38)]),
            // the hub and the pad → hub bridge
            CircuitSite(x: -5.5, z: 23.5, zones: [r(-8, 18, 6, 38), r(6, 27, 22, 33)]),
            // beacon A and the hub → A catwalk
            CircuitSite(x: -37.5, z: 21.5, zones: [r(-40, 18, -24, 36), r(-24, 25, -8, 31)]),
            // the plaza, its catwalks east and west, the stairs up to the hub
            CircuitSite(x: 5.5, z: -5.5, zones: [r(-12, -12, 10, 2), r(10, -8, 22, -2), r(-26, -9, -12, -3), r(-4, 2, 2, 18)]),
            // beacon B and the east loop
            CircuitSite(x: 24.5, z: -3.5, zones: [r(22, -16, 38, 0), r(30, 0, 34, 22)]),
            // beacon C and the west loop
            CircuitSite(x: -39.5, z: -4.5, zones: [r(-42, -18, -26, 0), r(-36, 0, -32, 18)]),
            // the stairs down to the lift (its breaker on the bottom landing)
            CircuitSite(x: -1.5, z: -30.5, zones: [r(-6, -32.5, 0, -12)]),
        ]
        let valves = [
            ValveSite(x: 13, y: 4.5, z: 26.4, from: Vec2(7.5, 28.4), to: Vec2(20.5, 28.4)),
            ValveSite(x: 26, y: 1.0, z: -16.3, from: Vec2(22.5, -14.4), to: Vec2(29.5, -14.4)),
            ValveSite(x: 34, y: 1.0, z: -16.3, from: Vec2(30.5, -14.4), to: Vec2(37.5, -14.4)),
            ValveSite(x: -3, y: 2.0, z: -12.4, from: Vec2(-5.5, -14.2), to: Vec2(-0.5, -14.2), width: 1.4),
        ]
        // (on the hub's north rail, between its lamp at x −5 and the crates at x 4)
        let lockers = [LockerSite(x: 0, z: 36.4, yaw: Float.pi)]
        return PropLayout(valves: valves, circuits: circuits, lockers: lockers)
    }()

    /// The interactives demo's set: `kelvin` plus a coolant line 0.6 m outside the hub's west rail (4 m, its mist over the
    /// hub's west strip) — the coolant line belongs to the Reactor Ring arena (design §1.3 B); Kelvin-9's own set has steam
    /// valves only.
    public static let kelvinDemo: PropLayout = {
        var p = kelvin
        p.valves.append(ValveSite(x: -8.6, y: 4.0, z: 34.4, from: Vec2(-6.8, 31.6), to: Vec2(-6.8, 37.2), width: 1.2, kind: .coolant))
        return p
    }()
}

// ---------- the station's lamps ----------
/// A deck lamp: a post on the railing line with an arm over the deck (WorldLevel's `lamp_post`, every 12 m along the
/// railing runs). `circuit` −1: on no circuit (it always burns and lights nothing the game counts).
public struct LampSite: Equatable {
    /// The post (plan) and the deck height under it.
    public var x: Float, z: Float, y: Float
    /// Inward unit normal: the arm reaches over the deck this way.
    public var nx: Float, nz: Float
    public var circuit: Int
    /// Where its light falls on the deck (1.4 m in from the post): the centre of its lit circle.
    public var pool: Vec2 { Vec2(x + nx * 1.4, z + nz * 1.4) }
    /// The deck point under its lens (0.85 m in): where a spitter's glob lands to break it.
    public var foot: Vec2 { Vec2(x + nx * 0.85, z + nz * 0.85) }
    /// The lens (world): 2.95 m over the deck at the end of the arm.
    public var lens: SIMD3<Float> { SIMD3(x + nx * 0.85, y + 2.95, z + nz * 0.85) }
}

/// The station's lamp posts in WorldLevel's order (`buildEdges`): the railing runs — the sides of walkable cells
/// (not the lift's) that face the abyss, merged per grid line, the lines in key order — and on every run of 6 m or more a
/// lamp from 3 m in, then every 12 m, standing on the rail line (0.12 m inside the deck edge).
public enum StationLamps {
    public static let spacing: Float = 12, firstAt: Float = 3, minRun: Float = 6

    public static func place(_ level: Level) -> [LampSite] {
        let G = GRID
        var h: [String: [(Int, Float, Float)]] = [:], v: [String: [(Int, Float, Float)]] = [:]
        for j in 1..<(G - 1) {
            for i in 1..<(G - 1) {
                let c = j * G + i
                if level.walkValue(c) == 0 || level.isLiftCell(c) { continue }
                let x = Float(i) - GRID_HALF, z = Float(j) - GRID_HALF
                if level.walkValue(c - G) == 0 { h["n\(j)", default: []].append((i, z + 0.12, 1)) }
                if level.walkValue(c + G) == 0 { h["s\(j)", default: []].append((i, z + 1 - 0.12, -1)) }
                if level.walkValue(c - 1) == 0 { v["w\(i)", default: []].append((j, x + 0.12, 1)) }
                if level.walkValue(c + 1) == 0 { v["e\(i)", default: []].append((j, x + 1 - 0.12, -1)) }
            }
        }
        var out: [LampSite] = []
        for (map, horiz) in [(h, true), (v, false)] {
            for key in map.keys.sorted() {
                let segs = map[key]!.sorted { $0.0 < $1.0 }
                var s0 = segs[0].0, prev = s0
                for k in 1...segs.count {
                    if k < segs.count && segs[k].0 == prev + 1 { prev = segs[k].0; continue }
                    let last = segs[k - 1]
                    lamps(on: Float(s0) - GRID_HALF, Float(prev + 1) - GRID_HALF, line: last.1, inward: last.2, horiz: horiz, level, &out)
                    if k < segs.count { s0 = segs[k].0; prev = s0 }
                }
            }
        }
        return out
    }

    private static func lamps(on a: Float, _ b: Float, line: Float, inward: Float, horiz: Bool, _ level: Level, _ out: inout [LampSite]) {
        let len = b - a
        if len < minRun { return }
        func P(_ t: Float, _ off: Float = 0) -> (Float, Float) { horiz ? (a + t, line + off * inward) : (line + off * inward, a + t) }
        var t = firstAt
        while t < len - 1 {
            let (x, z) = P(t)
            let (hx, hz) = P(clampf(t, 0.02, len - 0.02), 0.3)
            out.append(LampSite(x: x, z: z, y: level.groundY(hx, hz), nx: horiz ? 0 : inward, nz: horiz ? inward : 0, circuit: -1))
            t += spacing
        }
    }

    /// The lamps of a level with the circuit of each (the first circuit whose decks claim its post; −1 none).
    public static func assign(_ lamps: [LampSite], _ circuits: [CircuitSite]) -> [LampSite] {
        lamps.map { l in
            var o = l
            o.circuit = circuits.firstIndex { $0.claims(l.x, l.z) } ?? -1
            return o
        }
    }
}
