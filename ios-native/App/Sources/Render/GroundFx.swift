import SpriteKit
import IceHiveCore

/// Procedural ring indicator (web ringIndMat): progress pie, dashed remainder, pulsing inner disc.
/// Drawn on an untextured sprite so v_tex_coord spans 0…1 (atlas textures would not).
final class RingIndicator {
    static let source = """
    void main() {
        vec2 p = v_tex_coord * 2.0 - 1.0;
        float r = length(p);
        float ang = fract(atan(p.x, p.y) / 6.2831853 + 1.0);
        float ring = smoothstep(0.84, 0.865, r) * (1.0 - smoothstep(0.955, 0.98, r));
        float seg = step(0.3, fract(ang * 40.0));
        float prog = step(ang, u_prog);
        float inner = (1.0 - smoothstep(0.0, 0.86, r)) * 0.05 * (0.6 + 0.4 * sin(u_time * 3.0 - r * 8.0));
        float sw = 1.0 - smoothstep(0.0, 0.86, abs(r - fract(u_time * 0.5) * 0.86));
        float sweep = sw * 0.12 * step(r, 0.86) * (1.0 - step(0.999, u_prog));
        vec3 c = u_col.rgb * (ring * (prog * 1.7 + (1.0 - prog) * 0.35 * seg) + inner + sweep);
        c = vec3(1.0) - exp(-c * 1.3);
        gl_FragColor = vec4(c * u_alpha, 1.0);
    }
    """

    let node: SKSpriteNode
    private let uProg = SKUniform(name: "u_prog", float: 0)
    private let uCol = SKUniform(name: "u_col", vectorFloat4: SIMD4<Float>(0.25, 0.9, 0.85, 1))
    private let uAlpha = SKUniform(name: "u_alpha", float: 1)

    init(radius: Float) {
        let d = CGFloat(radius * 2) * Iso.ppm
        node = SKSpriteNode(color: .white, size: CGSize(width: d, height: d))
        let sh = SKShader(source: RingIndicator.source, uniforms: [uProg, uCol, uAlpha])
        node.shader = sh
        node.blendMode = .add
        node.zRotation = Iso.groundRotation(0)
        node.zPosition = ZBand.floorGlow + 2
        node.isHidden = true
    }

    func show(x: Float, y: Float, z: Float, progress: Float, r: Float, g: Float, b: Float, alpha: Float) {
        let p = Iso.point(x, y, z)
        node.position = CGPoint(x: p.x, y: p.y / Iso.groundSquash)
        uProg.floatValue = progress
        uCol.vectorFloat4Value = SIMD4<Float>(r, g, b, 1)
        uAlpha.floatValue = alpha
        if node.isHidden { node.isHidden = false }
    }

    func hide() { if !node.isHidden { node.isHidden = true } }
}

// ================================================================
//  GROUND FX — everything lying on the deck: multiply stains (ring
//  buffer), corpses (ring buffer), light splashes, telegraphs and the
//  beacon / lift / revive indicators.
// ================================================================
final class GroundFx {
    /// SpriteKit's .multiply is plain dst · src, so transparent (premultiplied black) texels would stamp black squares:
    /// output mix(1, colour, alpha) = 1 − a + rgb·a instead (one shared shader keeps the stains batched).
    static let decalShader = SKShader(source: """
    void main() {
        vec4 c = texture2D(u_texture, v_tex_coord);
        gl_FragColor = vec4(vec3(1.0 - c.a) + c.rgb, 1.0);
    }
    """)

    private let assets: SpriteAssets
    private let level: Level
    private let groundRoot: SKNode
    private let worldRoot: SKNode
    private let decals: SpriteRing
    private let corpses: SpriteRing
    private let splashPool: SpritePool
    private let telePool: SpritePool
    private var rng = SeededRNG(seed: 4242)
    private let glowTex: SKTexture
    private let ringTex: SKTexture, fillTex: SKTexture, laneTex: SKTexture

    private struct Splash { var x: Float; var z: Float; var size: Float; var r: Float; var g: Float; var b: Float; var t: Float; var life: Float }
    private var splashes: [Splash] = []

    let beaconInd: [RingIndicator]
    let liftInd: RingIndicator
    let reviveInd: [RingIndicator]

    init(assets: SpriteAssets, level: Level, groundRoot: SKNode, worldRoot: SKNode, decalCap: Int, corpseCap: Int) {
        self.assets = assets
        self.level = level
        self.groundRoot = groundRoot
        self.worldRoot = worldRoot
        decals = SpriteRing(parent: groundRoot, capacity: decalCap) { n in
            n.blendMode = .multiply
            n.shader = GroundFx.decalShader
            n.zPosition = ZBand.decal
        }
        corpses = SpriteRing(parent: worldRoot, capacity: corpseCap) { n in
            n.zPosition = ZBand.corpse
            n.colorBlendFactor = 1
        }
        splashPool = SpritePool(parent: groundRoot, capacity: 48) { n in
            n.blendMode = .add
            n.zPosition = ZBand.floorGlow
            n.colorBlendFactor = 1
        }
        telePool = SpritePool(parent: groundRoot, capacity: 112) { n in
            n.blendMode = .add
            n.zPosition = ZBand.floorGlow + 1
            n.colorBlendFactor = 1
        }
        glowTex = assets.texture("glow")
        ringTex = assets.texture("tele_ring")
        fillTex = assets.texture("tele_fill")
        laneTex = assets.texture("tele_lane")
        beaconInd = level.layout.beacons.map { _ in RingIndicator(radius: BEACON_R) }
        liftInd = RingIndicator(radius: level.lift.r - 0.3)
        reviveInd = (0..<4).map { _ in RingIndicator(radius: 1.5) }
        for ind in beaconInd { groundRoot.addChild(ind.node) }
        groundRoot.addChild(liftInd.node)
        for ind in reviveInd { groundRoot.addChild(ind.node) }
    }

    @inline(__always) private func gpos(_ x: Float, _ y: Float, _ z: Float) -> CGPoint {
        let p = Iso.point(x, y, z)
        return CGPoint(x: p.x, y: p.y / Iso.groundSquash)
    }

    private func walkable2(_ x: Float, _ z: Float) -> Bool {
        let c = level.cellOf(x, z)
        return c >= 0 && level.walkValue(c) != 0
    }

    // ---------------------------------------------------------------- stains
    /// A multiply stain from the Ground atlas (pre-tinted name), size = full texture width in metres.
    func addDecal(_ name: String, x: Float, z: Float, size s0: Float, rot: Float? = nil) {
        if !walkable2(x, z) { return }
        var size = s0
        var k = 0
        while k < 3 {
            let h = size * 0.4
            if walkable2(x - h, z - h) && walkable2(x + h, z - h) && walkable2(x - h, z + h) && walkable2(x + h, z + h) { break }
            size *= 0.7
            k += 1
        }
        let n = decals.next()
        let tex = assets.texture(name)
        if n.texture !== tex { n.texture = tex }
        let d = CGFloat(size) * Iso.ppm
        n.size = CGSize(width: d, height: d)
        n.position = gpos(x, level.groundY(x, z), z)
        n.zRotation = Iso.groundRotation(rot ?? rng.next() * 2 * Float.pi)
    }

    // ---------------------------------------------------------------- corpses
    func addCorpse(type: BugType, x: Float, z: Float, scale: Float) {
        if !walkable2(x, z) { return }
        let t = type.rawValue
        let n = corpses.next()
        let info = assets.corpseInfo[t]
        let k = CGFloat(scale / assets.bugBakedScale[t])
        n.show(assets.corpse(t, Int(rng.next() * 6)), size: CGSize(width: info.size.width * k, height: info.size.height * k), anchor: info.anchor)
        n.position = Iso.point(x, level.groundY(x, z), z)
        let v = CGFloat(0.75 + rng.next() * 0.25)
        n.color = SKColor(red: v, green: v * 0.92, blue: v * 0.9, alpha: 1)
    }

    // ---------------------------------------------------------------- light splashes
    /// Persistent splash that fades out over `life` (web splash()).
    func splash(_ x: Float, _ z: Float, _ size: Float, _ r: Float, _ g: Float, _ b: Float, _ life: Float) {
        let s = Splash(x: x, z: z, size: size, r: r, g: g, b: b, t: 0, life: life)
        if splashes.count < 16 { splashes.append(s); return }
        var worst = 0
        for k in 1..<splashes.count where splashes[k].t / splashes[k].life > splashes[worst].t / splashes[worst].life { worst = k }
        splashes[worst] = s
    }

    func beginFrame() { splashPool.begin(); telePool.begin() }

    /// One-frame splash (continuous emitters re-add it every frame).
    func splashNow(_ x: Float, _ z: Float, _ size: Float, _ r: Float, _ g: Float, _ b: Float) {
        let c0 = level.cellOf(x, z)
        if c0 < 0 || level.walkValue(c0) == 0 { return }
        guard let n = splashPool.next() else { return }
        if n.texture !== glowTex { n.texture = glowTex }
        let d = CGFloat(size) * Iso.ppm
        n.size = CGSize(width: d, height: d)
        n.position = gpos(x, level.groundY(x, z), z)
        n.color = Tone.color(r, g, b)
    }

    func updateSplashes(dt: Float) {
        var k = 0
        while k < splashes.count {
            splashes[k].t += dt
            let e = splashes[k]
            if e.t >= e.life { splashes.remove(at: k); continue }
            let f = (1 - e.t / e.life) * (1 - e.t / e.life)
            splashNow(e.x, e.z, e.size * (0.8 + 0.2 * e.t / e.life), e.r * f, e.g * f, e.b * f)
            k += 1
        }
    }

    // ---------------------------------------------------------------- telegraphs (from game.telegraphs)
    func updateTelegraphs(game: Game, time: Float) {
        let blink = 0.55 + 0.45 * sinf(time * 18)
        for e in game.telegraphs where e.active {
            guard let n = telePool.next() else { break }
            let u = e.progress
            var inten: Float
            switch e.shape {
            case .lane:
                let wind = max(0.001, e.wind)
                if e.t < e.wind {
                    inten = blink * min(1, e.t / wind * 4 + 0.3) * (0.8 + 0.5 * e.t / wind)
                } else {
                    inten = 1.3 * (1 - (e.t - e.wind) / max(0.001, e.life - e.wind))
                }
                if n.texture !== laneTex { n.texture = laneTex }
                let cx = e.x + e.dx * e.len / 2, cz = e.z + e.dz * e.len / 2
                n.size = CGSize(width: CGFloat(e.w) * Iso.ppm, height: CGFloat(e.len) * Iso.ppm)
                n.position = gpos(cx, level.groundY(cx, cz), cz)
                n.zRotation = Iso.groundRotation(atan2f(-e.dx, -e.dz))
            case .fill:
                let rad = e.r0 * (0.12 + 0.88 * u) * 2
                inten = (0.3 + 0.7 * u) * (u > 0.75 ? blink * 1.3 : 1)
                if n.texture !== fillTex { n.texture = fillTex }
                n.size = CGSize(width: CGFloat(rad) * Iso.ppm, height: CGFloat(rad) * Iso.ppm)
                n.position = gpos(e.x, level.groundY(e.x, e.z), e.z)
                n.zRotation = 0
            case .ring:
                inten = e.pulse ? blink * min(1, u * 4 + 0.3) : 1 - u
                let s = u * u * (3 - 2 * u)
                let rad = (e.r0 + (e.r1 - e.r0) * s) * 2
                if n.texture !== ringTex { n.texture = ringTex }
                n.size = CGSize(width: CGFloat(rad) * Iso.ppm, height: CGFloat(rad) * Iso.ppm)
                n.position = gpos(e.x, level.groundY(e.x, e.z), e.z)
                n.zRotation = 0
            }
            inten = max(0, inten)
            n.color = Tone.color(e.r * inten, e.g * inten, e.b * inten)
        }
    }

    /// Team ring under a marine (additive, laser colour).
    func teamRing(x: Float, y: Float, z: Float, diameter: Float, color: SKColor) {
        guard let n = telePool.next() else { return }
        if n.texture !== ringTex { n.texture = ringTex }
        let d = CGFloat(diameter) * Iso.ppm
        n.size = CGSize(width: d, height: d)
        n.position = gpos(x, y, z)
        n.zRotation = 0
        n.color = color
    }

    func endFrame() { splashPool.end(); telePool.end() }

    func clear() {
        decals.clear()
        corpses.clear()
        splashes.removeAll()
        for ind in beaconInd { ind.hide() }
        liftInd.hide()
        for ind in reviveInd { ind.hide() }
    }

    var nodeCount: Int { decals.count + corpses.count + splashPool.used + telePool.used }
}
