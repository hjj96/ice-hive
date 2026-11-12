import Foundation

// ================================================================
//  SWARM — bug storage as struct-of-arrays (port of the B object in 05-sim.js)
//  Fixed-capacity raw buffers: hot loops read them through local pointer
//  copies, no ARC / bounds / exclusivity overhead. Dead bugs stay in place
//  (flag `dead`) until `compact()` swaps the last live one into each hole at
//  the start of the next tick, so indices are stable within a tick; AI and
//  turret targets are validated by `uid`.
// ================================================================
public final class Swarm {
    public let capacity: Int
    /// Number of slots in use (live + dead-not-yet-compacted).
    public internal(set) var count: Int = 0
    var deadPending: Int = 0
    var uidSeq: Int32 = 1

    // Float arrays
    let x: UnsafeMutablePointer<Float>, z: UnsafeMutablePointer<Float>
    /// Position at the start of the current tick (render interpolation).
    let px: UnsafeMutablePointer<Float>, pz: UnsafeMutablePointer<Float>
    let vx: UnsafeMutablePointer<Float>, vz: UnsafeMutablePointer<Float>
    /// Height offset (climbing up from the abyss is negative; falling with the lift).
    let y: UnsafeMutablePointer<Float>
    let hp: UnsafeMutablePointer<Float>, hpMax: UnsafeMutablePointer<Float>
    /// Body radius (collision), visual scale.
    let r: UnsafeMutablePointer<Float>, sc: UnsafeMutablePointer<Float>
    let spd: UnsafeMutablePointer<Float>
    /// State timer, attack cooldown.
    let t: UnsafeMutablePointer<Float>, cd: UnsafeMutablePointer<Float>
    /// Chill 0..1 (slow), freeze timer, burn timer.
    let chill: UnsafeMutablePointer<Float>, frz: UnsafeMutablePointer<Float>, burn: UnsafeMutablePointer<Float>
    /// Gait phase, heading (atan2(dx, dz)), hit flash.
    let ph: UnsafeMutablePointer<Float>, hd: UnsafeMutablePointer<Float>, fl: UnsafeMutablePointer<Float>
    /// State vector: climb direction / charge direction / spit target point.
    let ax: UnsafeMutablePointer<Float>, az: UnsafeMutablePointer<Float>
    /// Per-bug random variation 0..1 (render tint, climb speed).
    let vr: UnsafeMutablePointer<Float>
    /// Separation mass (from the type).
    let ms: UnsafeMutablePointer<Float>
    /// Wave pacing (`Difficulty.waves`): the bug's mood (0 calm, 1 hesitate, 2 feint, 3 surge, 4 flee, 5 panic), its
    /// timer, the mood's direction (flight from a blast, a panicked dart) and the runner's leap cooldown.
    let mood: UnsafeMutablePointer<UInt8>
    let mt: UnsafeMutablePointer<Float>, mdx: UnsafeMutablePointer<Float>, mdz: UnsafeMutablePointer<Float>
    let lt: UnsafeMutablePointer<Float>
    /// The overhead (GameOverhead.swift): the route edge and travel direction (+(e + 1) heading a → b, −(e + 1) heading
    /// b → a, 0 = not on a route), the distance along that edge from its node a, the start of a drop / fall (x, absolute
    /// y, z), and `up`: 1 = filed under the spatial hash's sentinel bucket (out of reach of every deck query).
    let re: UnsafeMutablePointer<Int16>
    let rs: UnsafeMutablePointer<Float>
    let rx: UnsafeMutablePointer<Float>, ry: UnsafeMutablePointer<Float>, rz: UnsafeMutablePointer<Float>
    let up: UnsafeMutablePointer<UInt8>
    // byte arrays
    let type: UnsafeMutablePointer<UInt8>, st: UnsafeMutablePointer<UInt8>, dead: UnsafeMutablePointer<UInt8>
    /// Brute charge: bit k = marine k already hit by this charge.
    let hit: UnsafeMutablePointer<UInt8>
    /// Who set it on fire (-1 none).
    let bsrc: UnsafeMutablePointer<Int8>
    let uid: UnsafeMutablePointer<Int32>
    /// Stage 2 B1, the boss framework: 0 = not a boss; BOSS_BUG (255) = a boss's bug body (the Queen); k + 1 = part k of a
    /// boss's chain body (its hits route to the boss bar, GameBoss.bossPartHit). Its immunities read the boss's spec.
    let boss: UnsafeMutablePointer<UInt8>

    private let floats: [UnsafeMutablePointer<Float>]
    private let bytes: [UnsafeMutablePointer<UInt8>]

    init(capacity: Int = MAX_BUGS) {
        self.capacity = capacity
        func f() -> UnsafeMutablePointer<Float> { let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity); p.initialize(repeating: 0, count: capacity); return p }
        func b() -> UnsafeMutablePointer<UInt8> { let p = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity); p.initialize(repeating: 0, count: capacity); return p }
        x = f(); z = f(); px = f(); pz = f(); vx = f(); vz = f(); y = f(); hp = f(); hpMax = f(); r = f(); spd = f(); sc = f(); t = f(); cd = f()
        chill = f(); frz = f(); burn = f(); ph = f(); hd = f(); fl = f(); ax = f(); az = f(); vr = f(); ms = f()
        mt = f(); mdx = f(); mdz = f(); lt = f()
        rs = f(); rx = f(); ry = f(); rz = f()
        type = b(); st = b(); dead = b(); hit = b(); mood = b(); up = b(); boss = b()
        bsrc = .allocate(capacity: capacity); bsrc.initialize(repeating: -1, count: capacity)
        uid = .allocate(capacity: capacity); uid.initialize(repeating: 0, count: capacity)
        re = .allocate(capacity: capacity); re.initialize(repeating: 0, count: capacity)
        floats = [x, z, px, pz, vx, vz, y, hp, hpMax, r, spd, sc, t, cd, chill, frz, burn, ph, hd, fl, ax, az, vr, ms, mt, mdx, mdz, lt,
                  rs, rx, ry, rz]
        bytes = [type, st, dead, hit, mood, up, boss]
    }

    deinit {
        for p in floats { p.deallocate() }
        for p in bytes { p.deallocate() }
        bsrc.deallocate(); uid.deallocate(); re.deallocate()
    }

    /// Remove dead bugs by swapping the last live one into each hole.
    func compact() {
        if deadPending == 0 { return }
        let D = dead
        var n = count
        var rr = n - 1
        while rr >= 0 {
            if D[rr] != 0 {
                n -= 1
                let l = n
                if rr != l {
                    for A in floats { A[rr] = A[l] }
                    for A in bytes { A[rr] = A[l] }
                    bsrc[rr] = bsrc[l]; uid[rr] = uid[l]; re[rr] = re[l]
                }
            }
            rr -= 1
        }
        count = n
        deadPending = 0
    }

    func clear() { count = 0; deadPending = 0 }

    /// Remember the current positions as the previous ones (start of a tick).
    func storePrevious() {
        if count > 0 { px.update(from: x, count: count); pz.update(from: z, count: count) }
    }

    /// Live (not dead) bugs.
    public var aliveCount: Int {
        var n = 0
        for i in 0..<count where dead[i] == 0 { n += 1 }
        return n
    }

    /// Copy of all arrays for slots 0..<count (bench save/restore).
    struct Snapshot {
        var count: Int
        var deadPending: Int
        var floats: [[Float]]
        var bytes: [[UInt8]]
        var bsrc: [Int8]
        var uid: [Int32]
        var re: [Int16]
    }
    func snapshot() -> Snapshot {
        let n = count
        return Snapshot(count: n, deadPending: deadPending,
                        floats: floats.map { Array(UnsafeBufferPointer(start: $0, count: n)) },
                        bytes: bytes.map { Array(UnsafeBufferPointer(start: $0, count: n)) },
                        bsrc: Array(UnsafeBufferPointer(start: bsrc, count: n)),
                        uid: Array(UnsafeBufferPointer(start: uid, count: n)),
                        re: Array(UnsafeBufferPointer(start: re, count: n)))
    }
    func restore(_ s: Snapshot) {
        count = s.count; deadPending = s.deadPending
        for (k, A) in floats.enumerated() { for i in 0..<s.count { A[i] = s.floats[k][i] } }
        for (k, A) in bytes.enumerated() { for i in 0..<s.count { A[i] = s.bytes[k][i] } }
        for i in 0..<s.count { bsrc[i] = s.bsrc[i]; uid[i] = s.uid[i]; re[i] = s.re[i] }
    }

    // ---------- read-only render access ----------
    // Slots 0..<count; skip slots with isDead(i). Positions are world x/z, heights relative to the floor.
    @inline(__always) public func isDead(_ i: Int) -> Bool { dead[i] != 0 }
    @inline(__always) public func position(_ i: Int) -> Vec2 { Vec2(x[i], z[i]) }
    @inline(__always) public func bugType(_ i: Int) -> BugType { BugType(rawValue: Int(type[i])) ?? .runner }
    @inline(__always) public func state(_ i: Int) -> BugState { BugState(rawValue: st[i]) ?? .move }
    public var xs: UnsafePointer<Float> { UnsafePointer(x) }
    public var zs: UnsafePointer<Float> { UnsafePointer(z) }
    /// Positions at the start of the last tick: lerp(prev, current, alpha) for smooth rendering above 60 Hz.
    public var prevXs: UnsafePointer<Float> { UnsafePointer(px) }
    public var prevZs: UnsafePointer<Float> { UnsafePointer(pz) }
    public var velocityX: UnsafePointer<Float> { UnsafePointer(vx) }
    public var velocityZ: UnsafePointer<Float> { UnsafePointer(vz) }
    /// Height offset below/above the floor (climbing, falling with the lift).
    public var heights: UnsafePointer<Float> { UnsafePointer(y) }
    public var headings: UnsafePointer<Float> { UnsafePointer(hd) }
    public var scales: UnsafePointer<Float> { UnsafePointer(sc) }
    public var radii: UnsafePointer<Float> { UnsafePointer(r) }
    public var gaitPhases: UnsafePointer<Float> { UnsafePointer(ph) }
    /// Hit flash 0..0.6.
    public var flashes: UnsafePointer<Float> { UnsafePointer(fl) }
    public var burnTimers: UnsafePointer<Float> { UnsafePointer(burn) }
    public var freezeTimers: UnsafePointer<Float> { UnsafePointer(frz) }
    public var chills: UnsafePointer<Float> { UnsafePointer(chill) }
    /// State timers (swell progress = 1 - t / 0.8).
    public var stateTimers: UnsafePointer<Float> { UnsafePointer(t) }
    /// Brute charge direction / spitter target.
    public var stateDirX: UnsafePointer<Float> { UnsafePointer(ax) }
    public var stateDirZ: UnsafePointer<Float> { UnsafePointer(az) }
    public var variations: UnsafePointer<Float> { UnsafePointer(vr) }
    public var hps: UnsafePointer<Float> { UnsafePointer(hp) }
    public var maxHps: UnsafePointer<Float> { UnsafePointer(hpMax) }
    public var types: UnsafePointer<UInt8> { UnsafePointer(type) }
    public var states: UnsafePointer<UInt8> { UnsafePointer(st) }
    /// Wave pacing moods (BugMood raw values; all 0 on the legacy pacing).
    public var moods: UnsafePointer<UInt8> { UnsafePointer(mood) }
    public var deadFlags: UnsafePointer<UInt8> { UnsafePointer(dead) }
    public var uids: UnsafePointer<Int32> { UnsafePointer(uid) }
    // the overhead (Stage 1 R2): states ≥ BugState.high keep an ABSOLUTE height in `heights`
    /// The bug is up on the overhead (on a route, climbing a riser, coiling, early in a drop / fall).
    @inline(__always) public func isOverhead(_ i: Int) -> Bool { up[i] != 0 }
    /// `heights[i]` is an absolute world height (the overhead states), not the offset from the floor under the bug.
    @inline(__always) public func hasAbsoluteHeight(_ i: Int) -> Bool { st[i] >= S_HIGH }
    /// Route edge and direction of each bug: +(e + 1) heading a → b, −(e + 1) heading b → a, 0 = not on a route.
    public var routeEdges: UnsafePointer<Int16> { UnsafePointer(re) }
    /// Distance along that edge from its node a (m).
    public var routeParams: UnsafePointer<Float> { UnsafePointer(rs) }
    public var overheadFlags: UnsafePointer<UInt8> { UnsafePointer(up) }
    // the boss framework (Stage 2 B1)
    /// The slot is a boss's: its bug body (the Queen) or a part of its chain body.
    @inline(__always) public func isBoss(_ i: Int) -> Bool { boss[i] != 0 }
    /// The chain part a slot is (0 the head, 1… the segments, then the nodes; `Game.bossPart(_:)`), -1 none (a bug body
    /// too: it is drawn as its type).
    @inline(__always) public func bossPart(_ i: Int) -> Int { boss[i] != 0 && boss[i] != BOSS_BUG ? Int(boss[i]) - 1 : -1 }
}
