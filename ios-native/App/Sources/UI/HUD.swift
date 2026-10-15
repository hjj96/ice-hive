import SpriteKit
import UIKit
import IceHiveCore

/// Round touch button (ability / dash) with a cooldown sweep.
final class RoundButton {
    let node = SKNode()
    private let discIdle: SKSpriteNode
    private let discReady: SKSpriteNode
    private let cooldown = SKShapeNode()
    let label: Label
    private(set) var radius: CGFloat
    private var lastFraction: CGFloat = -1
    private var lastReady: Bool? = nil

    init(radius: CGFloat, text: String) {
        self.radius = radius
        discIdle = Shapes.circle(radius: radius, fill: UIPalette.panel, stroke: UIPalette.lineStrong, lineWidth: 2)
        discReady = Shapes.circle(radius: radius, fill: UIPalette.panel, stroke: UIPalette.amber, lineWidth: 3)
        cooldown.fillColor = UIPalette.rgba(0, 0, 0, 0.6)
        cooldown.strokeColor = .clear
        cooldown.lineWidth = 0
        label = Label(text, font: Fonts.semibold, size: 12, color: UIPalette.ink, kern: 0.5)
        node.addChild(discIdle)
        node.addChild(discReady)
        node.addChild(cooldown)
        node.addChild(label.node)
        label.node.zPosition = 1
    }

    func update(ready: Bool, fraction: CGFloat) {
        if lastReady != ready {
            lastReady = ready
            discReady.isHidden = !ready
            discIdle.isHidden = ready
            label.color = ready ? UIPalette.white : UIPalette.inkDim
        }
        let f = ready ? 0 : max(0, min(1, fraction))
        if abs(f - lastFraction) > 0.01 || (f == 0 && lastFraction != 0) {
            lastFraction = f
            cooldown.path = Shapes.pie(radius: radius - 1, fraction: f)
            cooldown.isHidden = f <= 0
        }
    }

    func contains(hudPoint p: CGPoint) -> Bool {
        let dx = p.x - node.position.x, dy = p.y - node.position.y
        let r = radius + 10
        return dx * dx + dy * dy <= r * r
    }
}

/// Floating virtual stick: ghost circle at rest, follows the thumb when active.
final class StickView {
    let node = SKNode()
    private let ring: SKSpriteNode
    private let knob: SKSpriteNode
    private let caption: Label
    static let radius: CGFloat = 56

    init(fire: Bool, caption text: String) {
        ring = Shapes.circle(radius: 62, fill: UIPalette.stickFill, stroke: fire ? UIPalette.fireRing : UIPalette.stickRing, lineWidth: 2)
        knob = Shapes.circle(radius: 27, fill: fire ? UIPalette.fireKnobFill : UIPalette.knobFill,
                             stroke: fire ? UIPalette.fireKnobRing : UIPalette.knobRing, lineWidth: 2)
        caption = Label(text, font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 1.9)
        caption.node.position = CGPoint(x: 0, y: -62 - 14)
        node.addChild(ring)
        node.addChild(knob)
        node.addChild(caption.node)
    }

    func idle(at p: CGPoint) {
        node.position = p
        knob.position = .zero
        node.alpha = 0.45
        caption.node.isHidden = false
    }

    func active(origin: CGPoint, knob offset: CGPoint) {
        node.position = origin
        knob.position = offset
        node.alpha = 1
        caption.node.isHidden = true
    }
}

// ================================================================
//  HUD — the in-game overlay (camera child), laid out like the web
//  #hud / #touchUI for portrait and landscape phones.
// ================================================================
final class HUD {
    let root = SKNode()
    private(set) var size = CGSize(width: 402, height: 874)
    private var insets = UIEdgeInsets.zero

    // top row
    private var statsPanel = SKSpriteNode(texture: nil)
    private let killsCap = Label("УБИТО", font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 1.4, align: .left)
    private let timeCap = Label("ВРЕМЯ", font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 1.4, align: .left)
    private let killsVal = Label("0", font: Fonts.monoBold, size: 17, color: UIPalette.ink, align: .left)
    private let timeVal = Label("0:00", font: Fonts.monoBold, size: 17, color: UIPalette.ink, align: .left)
    private let comboVal = Label("", font: Fonts.monoBold, size: 16, color: UIPalette.amber, align: .left)
    private var tealEdge = SKSpriteNode(color: UIPalette.teal, size: CGSize(width: 3, height: 44))
    private var pausePanel = SKSpriteNode(texture: nil)
    private let pauseBars = SKNode()
    private var pauseRect = CGRect.zero
    // objective
    private var objPanel = SKSpriteNode(texture: nil)
    private let objCap = Label("ЗАДАЧА", font: Fonts.medium, size: 12, color: UIPalette.amber, kern: 2.4)
    private let objText = Label("—", font: Fonts.semibold, size: 16, color: UIPalette.ink, kern: 0.6)
    private let objBar = Bar(width: 200, height: 4, fill: UIPalette.teal, track: UIPalette.tealTrack)
    private var objBottom: CGFloat = 0
    // squad
    private final class SquadRow {
        let node = SKNode()
        var panel = SKSpriteNode(texture: nil)
        let chip = SKSpriteNode(color: .white, size: CGSize(width: 3, height: 14))
        let name: Label
        let bar = Bar(width: 40, height: 4, fill: UIPalette.hp, track: UIPalette.hpBg, topLine: UIPalette.teal)
        init(name: String) {
            self.name = Label(name, font: Fonts.medium, size: 12, color: UIPalette.ink, kern: 1.0, align: .left)
        }
    }
    private var squad: [SquadRow] = []
    // toasts / hint / banner
    private final class Toast {
        let node = SKNode()
        let label = SKLabelNode()
        var panel: SKSpriteNode
        var t: Float = 0
        var life: Float
        var height: CGFloat = 26
        init(text: String, kind: ToastKind, maxWidth: CGFloat) {
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            label.numberOfLines = 0
            label.preferredMaxLayoutWidth = maxWidth
            label.horizontalAlignmentMode = .right
            label.verticalAlignmentMode = .top
            label.attributedText = NSAttributedString(string: text.uppercased(), attributes: [
                .font: Fonts.font(Fonts.medium, 12), .foregroundColor: UIPalette.ink, .kern: CGFloat(1.0), .paragraphStyle: style])
            life = kind == .warn ? 4.5 : 3.2
            panel = SKSpriteNode(texture: nil)
        }
    }
    private var toasts: [Toast] = []
    private let toastRoot = SKNode()
    private let hint = Label("", font: Fonts.semibold, size: 14, color: UIPalette.amber, kern: 1.1)
    private var hintUrgent = false
    private let banner = SKNode()
    private let bannerTitle = Label("", font: Fonts.bold, size: 34, color: UIPalette.red, kern: 4)
    private let bannerSub = Label("", font: Fonts.medium, size: 12, color: UIPalette.ink, kern: 3.6)
    private let bannerBand = SKSpriteNode(color: UIPalette.bannerRed, size: CGSize(width: 400, height: 52))
    private var bannerStripes: [SKSpriteNode] = []
    private var bannerT: Float = 99
    private var textT: Float = 0
    // bottom
    private let hpCap = Label("БРОНЯ", font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 1.4, align: .left)
    private let hpVal = Label("100", font: Fonts.monoBold, size: 13, color: UIPalette.ink, align: .right)
    private let hpBar = Bar(width: 228, height: 9, fill: UIPalette.hp, track: UIPalette.hpBg, topLine: UIPalette.teal, topHeight: 2)
    private let lvl = Label("УР 1", font: Fonts.monoBold, size: 12, color: UIPalette.amber, align: .left)
    private let xpBar = Bar(width: 190, height: 3, fill: UIPalette.amber, track: UIPalette.amberTrack)
    // touch controls
    let abilityButton = RoundButton(radius: 39, text: "ГРАНАТА")
    let dashButton = RoundButton(radius: 31, text: "РЫВОК")
    let stickL = StickView(fire: false, caption: "ДВИЖЕНИЕ")
    let stickR = StickView(fire: true, caption: "ОГОНЬ")
    private(set) var stickRestL = CGPoint.zero
    private(set) var stickRestR = CGPoint.zero
    // overlays
    private let vignette = SKSpriteNode(texture: nil)
    private let damage = SKSpriteNode(texture: nil)
    private let horde = SKSpriteNode(texture: nil)
    private let flash = SKSpriteNode(color: UIPalette.rgba(255, 240, 220, 1), size: CGSize(width: 10, height: 10))
    private var damageA: Float = 0, flashA: Float = 0, hordeA: Float = 0
    // nameplates + objective marker
    let plates = Nameplates()
    private let marker = SKNode()
    private let markerArrow = SKShapeNode()
    private let markerLabel = Label("", font: Fonts.monoBold, size: 12, color: UIPalette.amber)
    // debug
    /// -debugHUD text: two compact lines in the bottom-left corner (the SKView's own stats sit bottom-right).
    let debugLabel = Label("", font: Fonts.mono, size: 9, color: UIPalette.teal, align: .left, valign: .bottom)
    var showDebug = false
    var visible = true { didSet { root.isHidden = !visible } }

    init() {
        root.zPosition = ZBand.hud
        for n in [statsPanel, tealEdge, killsCap.node, timeCap.node, killsVal.node, timeVal.node, comboVal.node] as [SKNode] { root.addChild(n) }
        root.addChild(pausePanel)
        for k in 0..<2 {
            let b = SKSpriteNode(color: UIPalette.ink, size: CGSize(width: 4, height: 15))
            b.position = CGPoint(x: k == 0 ? -4.5 : 4.5, y: 0)
            pauseBars.addChild(b)
        }
        root.addChild(pauseBars)
        root.addChild(objPanel)
        root.addChild(objCap.node); root.addChild(objText.node); root.addChild(objBar.node)
        root.addChild(toastRoot)
        root.addChild(hint.node)
        banner.addChild(bannerBand)
        for _ in 0..<2 {
            let s = SKSpriteNode(texture: nil)
            s.alpha = 0.85
            banner.addChild(s)
            bannerStripes.append(s)
        }
        banner.addChild(bannerTitle.node)
        banner.addChild(bannerSub.node)
        banner.alpha = 0
        root.addChild(banner)
        for n in [hpCap.node, hpVal.node, hpBar.node, lvl.node, xpBar.node] as [SKNode] { root.addChild(n) }
        root.addChild(stickL.node); root.addChild(stickR.node)
        root.addChild(dashButton.node); root.addChild(abilityButton.node)
        vignette.texture = GeneratedTextures.vignette(edge: UIColor(red: 0.01, green: 0.02, blue: 0.04, alpha: 0.75), inner: 0.42)
        damage.texture = GeneratedTextures.vignette(edge: UIColor(red: 0.86, green: 0.04, blue: 0.04, alpha: 0.9), inner: 0.3)
        horde.texture = damage.texture
        vignette.zPosition = -20
        damage.zPosition = -19; damage.alpha = 0
        horde.zPosition = -18; horde.alpha = 0
        flash.zPosition = -17; flash.alpha = 0
        flash.blendMode = .add
        for n in [vignette, damage, horde, flash] { root.addChild(n) }
        plates.root.zPosition = -10
        root.addChild(plates.root)
        markerArrow.strokeColor = UIPalette.amber
        markerArrow.lineWidth = 3
        markerArrow.glowWidth = 2
        let ap = CGMutablePath()
        ap.move(to: CGPoint(x: -7, y: -5)); ap.addLine(to: CGPoint(x: 0, y: 4)); ap.addLine(to: CGPoint(x: 7, y: -5))
        markerArrow.path = ap
        marker.addChild(markerArrow)
        markerLabel.node.position = CGPoint(x: 0, y: -22)
        marker.addChild(markerLabel.node)
        marker.isHidden = true
        root.addChild(marker)
        debugLabel.node.numberOfLines = 0
        debugLabel.node.isHidden = true
        root.addChild(debugLabel.node)
    }

    /// View coordinates (UIKit, top-left origin, y down) → HUD coordinates.
    @inline(__always) func hp(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x - size.width / 2, y: size.height / 2 - y) }
    /// HUD coordinates → view coordinates.
    @inline(__always) func viewPoint(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + size.width / 2, y: size.height / 2 - p.y) }

    func setSquad(_ marines: [Marine]) {
        for r in squad { r.node.removeFromParent() }
        squad = marines.map { m in
            let r = SquadRow(name: m.isPlayer ? "ВЫ" : m.name)
            r.chip.color = UIPalette.classColors[m.cls.rawValue]
            r.node.addChild(r.panel); r.node.addChild(r.chip); r.node.addChild(r.name.node); r.node.addChild(r.bar.node)
            root.addChild(r.node)
            return r
        }
        if let p = marines.first {
            abilityButton.label.set(p.spec.abilityShort.uppercased())
        }
        plates.setSquad(marines)
        layout(size: size, insets: insets)
    }

    // ---------------------------------------------------------------- layout
    func layout(size: CGSize, insets: UIEdgeInsets) {
        self.size = size
        self.insets = insets
        let W = size.width, H = size.height
        let landscape = W > H
        let sl = max(16, insets.left), sr = max(16, insets.right), st = insets.top, sb = insets.bottom
        let top = 10 + st

        // stats panel (top-left); the time column moves right when the kill count gets wide (web: flex row)
        let statsH: CGFloat = landscape ? 40 : 44
        statsTop = top
        statsLeft = sl
        statsKillsW = -1
        fitStats()
        let statsW: CGFloat = landscape ? 124 : 130
        tealEdge.size = CGSize(width: 3, height: statsH)
        tealEdge.anchorPoint = CGPoint(x: 0, y: 1)
        tealEdge.position = hp(sl, top)
        killsCap.node.position = hp(sl + 13, top + 12)
        killsVal.node.position = hp(sl + 13, top + (landscape ? 29 : 31))

        // pause button (top-right)
        pausePanel.removeFromParent()
        pausePanel = Shapes.panel(width: 44, height: 44, stroke: UIPalette.lineStrong)
        pausePanel.position = hp(W - sr - 44, top)
        pausePanel.zPosition = -1
        root.addChild(pausePanel)
        pauseBars.position = hp(W - sr - 22, top + 22)
        pauseRect = CGRect(x: W - sr - 52, y: top - 8, width: 60, height: 60)

        // objective box: own row in portrait, between the stats and the pause button in landscape
        let objW: CGFloat, objX: CGFloat, objY: CGFloat
        if landscape {
            objW = min(480, W - sl - sr - statsW - 44 - 40)
            objX = (W - objW) / 2
            objY = top
        } else {
            objW = W - sl - sr
            objX = sl
            objY = top + statsH + 8
        }
        let objH: CGFloat = 46
        objPanel.removeFromParent()
        objPanel = Shapes.panel(width: objW, height: objH)
        objPanel.position = hp(objX, objY)
        objPanel.zPosition = -1
        root.addChild(objPanel)
        objCap.node.position = hp(objX + objW / 2, objY + 11)
        objText.size = W <= 600 ? 14 : 16
        objText.node.position = hp(objX + objW / 2, objY + 27)
        objBar.resize(width: objW - 32)
        objBar.node.position = hp(objX + 16, objY + objH - 5)
        objBottom = objY + objH

        // squad list
        let rowW: CGFloat = 117, rowH: CGFloat = 22
        let squadTop = landscape ? top + statsH + 8 : objBottom + 8
        for (k, r) in squad.enumerated() {
            let y = squadTop + CGFloat(k) * (rowH + 4)
            r.panel.removeFromParent()
            r.panel = Shapes.panel(width: rowW, height: rowH, cut: 5)
            r.panel.zPosition = -1
            r.node.addChild(r.panel)
            r.node.position = hp(sl, y)
            r.panel.position = .zero
            r.chip.position = CGPoint(x: 1.5, y: -rowH / 2)
            r.name.node.position = CGPoint(x: 9, y: -rowH / 2)
            r.bar.node.position = CGPoint(x: rowW - 46, y: -rowH / 2)
        }
        toastRoot.position = hp(W - sr, landscape ? top + 52 : objBottom + 8)

        // bottom: armour + level
        let boxW = landscape ? min(260, W * 0.32) : min(300, W * 0.52)
        let bottom = H - (landscape ? 8 : 12) - sb
        let bx = (W - boxW) / 2
        lvl.node.position = hp(bx, bottom - 6)
        xpBar.resize(width: boxW - 44)
        xpBar.node.position = hp(bx + 44, bottom - 6)
        hpBar.resize(width: boxW)
        hpBar.node.position = hp(bx, bottom - 12 - 6 - 4.5)
        hpCap.node.position = hp(bx, bottom - 12 - 6 - 9 - 4 - 8)
        hpVal.node.position = hp(bx + boxW, bottom - 12 - 6 - 9 - 4 - 8)

        // hint: portrait phones show it under the objective + squad list (web: top 226 + safe top), landscape low
        hint.node.position = landscape ? hp(W / 2 - 45, H - 64 - sb) : hp(W / 2, 226 + st + 8)

        // touch buttons (#tAbility / #tDash)
        let rIn = insets.right
        if landscape {
            abilityButton.node.position = hp(W - 16 - rIn - 39, H - 150 - sb - 39)
            dashButton.node.position = hp(W - 104 - rIn - 31, H - 196 - sb - 31)
        } else {
            abilityButton.node.position = hp(W - 14 - rIn - 39, H - 252 - sb - 39)
            dashButton.node.position = hp(W - 100 - rIn - 31, H - 230 - sb - 31)
        }
        // stick rest positions (placeStick)
        let sx = max(90, W * 0.16)
        let sy = H - sb - max(110, H * 0.17) - (landscape ? 0 : 20)
        stickRestL = hp(sx, sy)
        stickRestR = hp(W - sx - (landscape ? 90 : 0), sy)
        stickL.idle(at: stickRestL)
        stickR.idle(at: stickRestR)

        // banner
        let bw = min(560, W * 0.86)
        banner.position = hp(W / 2, H * (landscape ? 0.24 : 0.17) + st + 40)
        bannerTitle.size = max(30, min(64, W * 0.08))
        bannerBand.size = CGSize(width: W, height: bannerTitle.size + 22)
        bannerTitle.node.position = CGPoint(x: 0, y: 0)
        bannerSub.node.position = CGPoint(x: 0, y: -bannerTitle.size * 0.5 - 14)
        let stripes = GeneratedTextures.hazard(width: bw, height: 6)
        for (k, s) in bannerStripes.enumerated() {
            s.texture = stripes
            s.size = CGSize(width: bw, height: 6)
            s.position = CGPoint(x: 0, y: k == 0 ? bannerTitle.size * 0.5 + 14 : -bannerTitle.size * 0.5 - 30)
        }

        // overlays
        for n in [vignette, damage, horde, flash] { n.size = size; n.position = .zero }
        debugLabel.node.position = hp(max(8, insets.left), H - max(3, sb - 24))
        plates.topLimit = hp(0, objBottom + 4).y
    }

    private var statsTop: CGFloat = 0, statsLeft: CGFloat = 0, statsKillsW: CGFloat = -1

    /// Stats panel width / time column from the current kill-count width (re-built only when the column moves).
    private func fitStats() {
        let landscape = size.width > size.height
        let kw = max(38, (killsVal.width / 10).rounded(.up) * 10)
        if kw == statsKillsW { return }
        statsKillsW = kw
        let statsH: CGFloat = landscape ? 40 : 44
        let timeX = 13 + kw + 13
        let statsW = max(landscape ? 124 : 130, timeX + max(48, timeVal.width) + 14)
        statsPanel.removeFromParent()
        statsPanel = Shapes.panel(width: statsW, height: statsH)
        statsPanel.position = hp(statsLeft, statsTop)
        statsPanel.zPosition = -1
        root.addChild(statsPanel)
        timeCap.node.position = hp(statsLeft + timeX, statsTop + 12)
        timeVal.node.position = hp(statsLeft + timeX, statsTop + (landscape ? 29 : 31))
        comboVal.node.position = hp(statsLeft + statsW + 10, statsTop + statsH / 2)
    }

    // ---------------------------------------------------------------- events
    func toast(_ text: String, kind: ToastKind) {
        let maxW = min(320, size.width * 0.6)
        let t = Toast(text: text, kind: kind, maxWidth: maxW - 22)
        let tf = t.label.frame
        let w = min(maxW, max(80, tf.width + 22))
        t.height = max(26, tf.height + 12)
        t.panel = Shapes.panel(width: w, height: t.height, cut: 0)
        t.panel.position = CGPoint(x: -w, y: 0)
        t.node.addChild(t.panel)
        let edge = SKSpriteNode(color: kind == .warn ? UIPalette.red : (kind == .gold ? UIPalette.amber : UIPalette.teal), size: CGSize(width: 3, height: t.height))
        edge.anchorPoint = CGPoint(x: 1, y: 1)
        t.node.addChild(edge)
        t.label.position = CGPoint(x: -10, y: -6)
        t.node.addChild(t.label)
        t.node.alpha = 0
        toastRoot.addChild(t.node)
        toasts.append(t)
        if toasts.count > 4 { toasts[0].node.removeFromParent(); toasts.removeFirst() }
    }

    func showBanner(title: String, subtitle: String, teal: Bool) {
        bannerTitle.color = teal ? UIPalette.teal : UIPalette.red
        bannerTitle.set(title.uppercased())
        bannerSub.set(subtitle.uppercased())
        bannerBand.color = teal ? UIPalette.bannerTeal : UIPalette.bannerRed
        bannerT = 0
    }

    /// Loading-cover warm-up: every overlay, a banner, a toast and both cooldown pies on screen for a few frames
    /// (first use of each would otherwise build its pipeline / textures mid-game), then back to normal.
    func warmUp(_ on: Bool) {
        if on {
            screenFlash(0.6); damageFlash(0.8); hordeFlash()
            showBanner(title: "ОРДА!", subtitle: "РОЙ ПРОРЫВАЕТСЯ ИЗ БЕЗДНЫ", teal: false)
            toast("Связь установлена", kind: .info)
            toast("Плевун: плюётся кислотой", kind: .warn)
            abilityButton.update(ready: false, fraction: 0.5)
            dashButton.update(ready: false, fraction: 0.5)
            marker.isHidden = false
            damage.alpha = 0.5; flash.alpha = 0.3; horde.alpha = 0.5; banner.alpha = 1
        } else {
            damageA = 0; flashA = 0; hordeA = 0
            damage.alpha = 0; flash.alpha = 0; horde.alpha = 0
            bannerT = 99; banner.alpha = 0
            for t in toasts { t.node.removeFromParent() }
            toasts.removeAll()
            abilityButton.update(ready: true, fraction: 0)
            dashButton.update(ready: true, fraction: 0)
        }
    }

    func damageFlash(_ a: Float) { damageA = min(1, damageA + a) }
    func screenFlash(_ a: Float) { flashA = max(flashA, a) }
    func hordeFlash() { hordeA = 1 }

    /// HUD point inside the pause button?
    func pauseHit(viewPoint p: CGPoint) -> Bool { pauseRect.contains(p) }

    // ---------------------------------------------------------------- per frame
    func update(game: Game, dt: Float, camera: CameraController, marines: MarineLayer, input: InputController) {
        let P = game.player
        // fast-changing numbers at 10 Hz (each new string is a new label texture)
        textT -= dt
        if textT <= 0 {
            textT = 0.1
            killsVal.set("\(game.kills)")
            hpVal.set("\(Int(max(0, P.hp).rounded()))")
            fitStats()
        }
        timeVal.set(formatTime(game.time))
        let combo = game.comboShown
        comboVal.set(combo > 0 ? "×\(combo)" : "")
        comboVal.color = combo >= 100 ? UIPalette.white : (combo >= 50 ? UIPalette.red : UIPalette.amber)
        objText.set(game.objectiveText.uppercased())
        let prog = game.objectiveProgress
        objBar.node.isHidden = prog < 0
        objBar.set(CGFloat(max(0, prog)))
        // contextual hint (the control hint during the first 7 s is the app's job)
        var h = ""
        var urgent = false
        if let c = game.contextHint { h = c.text; urgent = c.urgent } else if game.time < 7 && !P.downed { h = "Левый палец — бег · правый — прицел и огонь" }
        hint.set(h.uppercased())
        if urgent != hintUrgent { hintUrgent = urgent; hint.color = urgent ? UIPalette.red : UIPalette.amber }
        hint.node.alpha = urgent ? (sinf(game.time * 7.85) > 0 ? 1 : 0.35) : 1

        for (k, r) in squad.enumerated() where k < game.marines.count {
            let m = game.marines[k]
            r.bar.set(CGFloat(m.hp / max(1, m.maxHp)))
            r.name.color = m.downed ? UIPalette.red : UIPalette.ink
            r.name.node.alpha = m.downed && sinf(game.time * 10.5) < 0 ? 0.3 : 1
        }
        hpBar.set(CGFloat(P.hp / max(1, P.maxHp)))
        lvl.set("УР \(game.xpLevel)")
        xpBar.set(CGFloat(Float(game.xp) / Float(max(1, game.xpNext))))

        abilityButton.update(ready: P.abilityReady, fraction: CGFloat(P.abilityCooldownFraction))
        dashButton.update(ready: P.dashReady, fraction: CGFloat(P.dashCooldownFraction))

        // sticks
        if let l = input.left {
            stickL.active(origin: hp(l.origin.x, l.origin.y), knob: input.knobOffset(l))
        } else {
            stickL.idle(at: stickRestL)
        }
        if let r = input.right {
            stickR.active(origin: hp(r.origin.x, r.origin.y), knob: input.knobOffset(r))
        } else {
            stickR.idle(at: stickRestR)
        }

        // toasts
        var y: CGFloat = 0
        var k = 0
        while k < toasts.count {
            let t = toasts[k]
            t.t += dt
            if t.t >= t.life { t.node.removeFromParent(); toasts.remove(at: k); continue }
            let u = t.t / t.life
            t.node.alpha = CGFloat(u < 0.08 ? u / 0.08 : (u > 0.85 ? (1 - u) / 0.15 : 1))
            t.node.position = CGPoint(x: u < 0.08 ? CGFloat((1 - u / 0.08) * 20) : 0, y: y)
            y -= t.height + 4
            k += 1
        }
        // banner (2.4 s)
        bannerT += dt
        if bannerT < 2.4 {
            let u = bannerT / 2.4
            var a: Float = 1
            if u < 0.08 { a = u / 0.08 } else if u < 0.15 { a = 1 - (u - 0.08) / 0.07 * 0.25 } else if u < 0.22 { a = 0.75 + (u - 0.15) / 0.07 * 0.25 } else if u > 0.8 { a = (1 - u) / 0.2 }
            banner.alpha = CGFloat(a)
            banner.setScale(CGFloat(u < 0.08 ? 1.25 - u / 0.08 * 0.25 : (u > 0.8 ? 1 - (u - 0.8) / 0.2 * 0.02 : 1)))
        } else if banner.alpha > 0 {
            banner.alpha = 0
        }
        // overlays
        damageA = max(0, damageA - dt * 1.6)
        flashA = max(0, flashA - dt * 3)
        hordeA = max(0, hordeA - dt * 0.9)
        let low = P.hp > 0 && P.hp < P.maxHp * 0.3 && !P.downed ? 0.25 + 0.15 * sinf(game.time * 6) : 0
        damage.alpha = CGFloat(min(1, damageA * 0.8 + low))
        flash.alpha = CGFloat(flashA * 0.45)
        horde.alpha = CGFloat(hordeA * (0.6 + 0.4 * sinf(game.time * 18)))

        plates.update(game: game, camera: camera, marines: marines, size: size)
        updateMarker(game: game, camera: camera)
    }

    private func updateMarker(game: Game, camera: CameraController) {
        guard let t = game.objectiveMarker else { marker.isHidden = true; return }
        marker.isHidden = false
        let gy = game.level.groundY(t.x, t.y)
        let s = camera.toHUD(Iso.point(t.x, gy + 1.2, t.y))
        let P = game.player
        let dist = hypotf(t.x - P.x, t.y - P.z)
        markerLabel.set("\(Int(dist.rounded())) м")
        let mx = size.width / 2 - 40, myTop = size.height / 2 - objBottom - 30, myBot = -size.height / 2 + 150
        let inside = abs(s.x) < mx && s.y < myTop && s.y > myBot
        if inside {
            marker.position = CGPoint(x: s.x, y: s.y + 18)
            markerArrow.zRotation = .pi
            markerArrow.setScale(0.7)
        } else {
            // clamp onto the screen edge along the direction from the centre
            let len = max(1, (s.x * s.x + s.y * s.y).squareRoot())
            let dx = s.x / len, dy = s.y / len
            var k = CGFloat.greatestFiniteMagnitude
            if abs(dx) > 1e-4 { k = min(k, mx / abs(dx)) }
            if dy > 1e-4 { k = min(k, myTop / dy) }
            if dy < -1e-4 { k = min(k, -myBot / -dy) }
            marker.position = CGPoint(x: dx * k, y: dy * k)
            markerArrow.zRotation = CGFloat(atan2(Double(dy), Double(dx))) - .pi / 2
            markerArrow.setScale(1)
        }
    }

    func setDebug(_ text: String) {
        debugLabel.node.isHidden = !showDebug
        if showDebug { debugLabel.set(text) }
    }
}

// ================================================================
//  NAMEPLATES — callsign + HP bar over each marine (web .plate),
//  stacked upward when they overlap.
// ================================================================
final class Nameplates {
    let root = SKNode()
    private final class Plate {
        let node = SKNode()
        let name: Label
        let bar: Bar
        let seg: Bar?
        let revive = SKSpriteNode(color: UIPalette.teal, size: CGSize(width: 76, height: 2))
        init(name text: String, player: Bool) {
            let w: CGFloat = player ? 96 : 76
            name = Label(text, font: player ? Fonts.semibold : Fonts.medium, size: 12, color: player ? UIPalette.white : UIPalette.ink, kern: 1.2)
            bar = Bar(width: w, height: 4, fill: UIPalette.hp, track: UIPalette.hpBg, topLine: UIPalette.teal)
            seg = player ? Bar(width: w, height: 3, fill: UIPalette.rgba(219, 230, 238, 0.8), track: .clear) : nil
            name.node.position = CGPoint(x: 0, y: -6)
            bar.node.position = CGPoint(x: -w / 2, y: -17)
            node.addChild(name.node)
            node.addChild(bar.node)
            if let s = seg { s.node.position = CGPoint(x: -w / 2, y: -23); node.addChild(s.node) }
            revive.anchorPoint = CGPoint(x: 0, y: 0.5)
            revive.size = CGSize(width: w, height: 2)
            revive.position = CGPoint(x: -w / 2, y: player ? -28 : -23)
            node.addChild(revive)
        }
    }
    private var plates: [Plate] = []
    var topLimit: CGFloat = 1e6
    private var px = [CGFloat](repeating: 0, count: 4), py = [CGFloat](repeating: 0, count: 4)

    func setSquad(_ marines: [Marine]) {
        for p in plates { p.node.removeFromParent() }
        plates = marines.map { m in
            let p = Plate(name: m.isPlayer ? "ВЫ" : m.name, player: m.isPlayer)
            root.addChild(p.node)
            return p
        }
    }

    func update(game: Game, camera: CameraController, marines: MarineLayer, size: CGSize) {
        let n = min(plates.count, game.marines.count)
        for k in 0..<n {
            let m = game.marines[k]
            let h = marines.head(k, downed: m.downed)
            let s = camera.toHUD(Iso.point(h.0, h.1, h.2))
            px[k] = s.x
            py[k] = s.y + 30
        }
        // overlapping plates stack upward (PLATE_GAP 26); near the objective box they spread sideways
        for _ in 0..<6 {
            for a in 0..<n {
                for b in (a + 1)..<max(a + 1, n) {
                    let dx = px[a] - px[b]
                    if abs(dx) > 84 { continue }
                    let dy = py[a] - py[b]
                    if abs(dy) >= 26 { continue }
                    let up = dy > 0 ? a : b, lo = up == a ? b : a
                    if py[lo] + 26 <= topLimit { py[up] = py[lo] + 26 } else {
                        let l = dx < 0 ? a : b, r = l == a ? b : a, mid = (px[a] + px[b]) / 2
                        px[l] = mid - 43; px[r] = mid + 43
                    }
                }
            }
        }
        let halfW = size.width / 2
        for k in 0..<n {
            let m = game.marines[k], p = plates[k]
            p.node.position = CGPoint(x: max(-halfW + 40, min(halfW - 40, px[k])), y: py[k])
            p.bar.set(CGFloat(m.hp / max(1, m.maxHp)))
            p.seg?.set(CGFloat(m.bar))
            if let s = p.seg { s.node.alpha = (m.overheated || m.reloading) ? (sinf(game.time * 18) > 0 ? 1 : 0.2) : 0.8 }
            p.name.color = m.downed ? UIPalette.red : (m.isPlayer ? UIPalette.white : UIPalette.ink)
            p.revive.xScale = max(0.0001, CGFloat(m.downed ? m.revive : 0))
            p.revive.isHidden = !m.downed
        }
    }
}
