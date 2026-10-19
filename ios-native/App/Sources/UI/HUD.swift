import SpriteKit
import UIKit
import IceHiveCore

/// Round touch button (ability / dash) with a cooldown sweep.
final class RoundButton {
    let node = SKNode()
    private let discIdle: SKSpriteNode
    private let discReady: SKSpriteNode
    /// Cooldown sweep: one of `Shapes.pieSteps` pre-rendered pie textures (no path re-tessellation per change).
    private let cooldown = SKSpriteNode(texture: nil)
    private let pies: [SKTexture]
    let label: Label
    private(set) var radius: CGFloat
    private var lastFraction: CGFloat = -1
    private var lastReady: Bool? = nil

    init(radius: CGFloat, text: String) {
        self.radius = radius
        discIdle = Shapes.circle(radius: radius, fill: UIPalette.panel, stroke: UIPalette.lineStrong, lineWidth: 2)
        discReady = Shapes.circle(radius: radius, fill: UIPalette.panel, stroke: UIPalette.amber, lineWidth: 3)
        pies = Shapes.pies(radius: radius - 1, color: UIPalette.rgba(0, 0, 0, 0.6))
        cooldown.size = CGSize(width: (radius - 1) * 2, height: (radius - 1) * 2)
        cooldown.isHidden = true
        label = Label(text, font: Fonts.semibold, size: 12, color: UIPalette.ink, kern: 0.5)
        node.addChild(discIdle)
        node.addChild(discReady)
        node.addChild(cooldown)
        node.addChild(label.node)
        label.node.zPosition = 1
    }

    /// Loading-cover warm-up: every pie texture on screen once (a texture is uploaded on its first draw — mid-mission
    /// that was up to 48 uploads per button over the first cooldowns), then gone.
    private var pieWarm: SKNode?
    func warmPies(_ on: Bool) {
        pieWarm?.removeFromParent()
        pieWarm = nil
        guard on else { return }
        let n = SKNode()
        for t in pies {
            let s = SKSpriteNode(texture: t)
            s.size = cooldown.size
            n.addChild(s)
        }
        node.addChild(n)
        pieWarm = n
    }

    func update(ready: Bool, fraction: CGFloat) {
        if lastReady != ready {
            lastReady = ready
            discReady.isHidden = !ready
            discIdle.isHidden = ready
            label.color = ready ? UIPalette.white : UIPalette.inkDim
        }
        let f = ready ? 0 : max(0, min(1, fraction))
        let step = Int((f * CGFloat(Shapes.pieSteps)).rounded(.up))
        if CGFloat(step) != lastFraction {
            lastFraction = CGFloat(step)
            if step <= 0 {
                cooldown.isHidden = true
            } else {
                let t = pies[min(pies.count - 1, step - 1)]
                if cooldown.texture !== t { cooldown.texture = t }
                cooldown.isHidden = false
            }
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

    /// `learned` (VX-5 ghost sticks, after 6 s of stick use): the resting stick is a whisper without its caption.
    func idle(at p: CGPoint, learned: Bool = false) {
        node.position = p
        knob.position = .zero
        node.alpha = learned ? 0.16 : 0.45
        caption.node.isHidden = learned
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
    // numbers that change every few frames: glyph-atlas labels (no text texture per new value)
    private let killsVal = GlyphLabel("0", font: Fonts.monoBold, size: 17, color: UIPalette.ink, charset: GlyphLabel.digits, align: .left)
    private let timeVal = GlyphLabel("0:00", font: Fonts.monoBold, size: 17, color: UIPalette.ink, charset: GlyphLabel.digits + ":", align: .left)
    private let comboVal = GlyphLabel("", font: Fonts.monoBold, size: 16, color: UIPalette.amber, charset: GlyphLabel.digits + "×", align: .left)
    private var comboLast = 0
    private var comboBumpT: Double = 0
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
    // v1.1: threat variants of the objective box (waking amber, converging red, the Матка violet) — left edge, colours,
    // the converging fill; the portrait box is trimmed to one line (VX-5: no «ЗАДАЧА», 13 pt, ≈ 32 pt tall)
    private let objEdge = SKSpriteNode(color: UIPalette.amber, size: CGSize(width: 3, height: 39))
    private var objStyle: ObjectiveStyle = .normal
    private var objRect = CGRect.zero   // x, y = top-left in view points (y down), size
    private var objTrim = false
    private var objBarShown = true
    // coach «Учебная высадка»: card under the objective, ghost thumb, pulsing target
    let coachCard = CoachCard()
    private let ghost = CoachGhost()
    private let abilityRing = SKSpriteNode(texture: nil)
    private let dashRing = SKSpriteNode(texture: nil)
    private let markerRing = SKSpriteNode(texture: Shapes.glowRing(radius: 19, color: UIPalette.amber, lineWidth: 3, glow: 12, inner: false))
    private var coachTarget: CoachTarget? = nil
    /// Bottom of the top HUD band (objective box, or the coach card under it), view points from the top.
    private var bandBottom: CGFloat = 0
    /// VX-5 ghost sticks: the resting sticks fade after 6 s of stick use.
    var sticksLearned = false
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
        let label: SKLabelNode
        /// label.frame when the label was made (asking a wrapped label for its frame lays it out again)
        let labelFrame: CGRect
        var panel: SKSpriteNode
        var t: Float = 0
        var life: Float
        var height: CGFloat = 26
        init(label: SKLabelNode, frame: CGRect, kind: ToastKind) {
            self.label = label
            labelFrame = frame
            life = kind == .warn ? 4.5 : 3.2
            panel = SKSpriteNode(texture: nil)
        }

        /// Off screen; the label is let go too (a cached one is reused by a later toast).
        func discard() {
            node.removeFromParent()
            label.removeFromParent()
        }

        static func makeLabel(_ text: String, maxWidth: CGFloat) -> SKLabelNode {
            let label = SKLabelNode()
            let style = NSMutableParagraphStyle()
            style.alignment = .right
            label.numberOfLines = 0
            label.preferredMaxLayoutWidth = maxWidth
            label.horizontalAlignmentMode = .right
            label.verticalAlignmentMode = .top
            label.attributedText = NSAttributedString(string: text.uppercased(), attributes: [
                .font: Fonts.font(Fonts.medium, 12), .foregroundColor: UIPalette.ink, .kern: CGFloat(1.0), .paragraphStyle: style])
            LabelStats.textsSet += 1
            return label
        }
    }
    /// Wrapped (two-line) toast labels, made once behind the loading cover and reused: making one mid-mission renders
    /// its text there and then, and CI saw that wait 1.5–9 s for the GPU during host stalls. Keyed by text and width.
    private var toastLabels: [String: (SKLabelNode, CGRect)] = [:]
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
    private let hpVal = GlyphLabel("100", font: Fonts.monoBold, size: 13, color: UIPalette.ink, charset: GlyphLabel.digits, align: .right)
    private let hpBar = Bar(width: 228, height: 9, fill: UIPalette.hp, track: UIPalette.hpBg, topLine: UIPalette.teal, topHeight: 2)
    private let lvl = GlyphLabel("УР 1", font: Fonts.monoBold, size: 12, color: UIPalette.amber, charset: GlyphLabel.digits + "УР", align: .left)
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
    private let markerArrow = SKSpriteNode(texture: Shapes.chevron(color: UIPalette.amber))
    private let markerLabel = GlyphLabel("", font: Fonts.monoBold, size: 12, color: UIPalette.amber, charset: GlyphLabel.digits + "м")
    private static let chevronAmber = Shapes.chevron(color: UIPalette.amber)
    private static let chevronRed = Shapes.chevron(color: UIPalette.red)
    /// The swarm converges: red marker throbbing 1 ↔ 1.3 (web #marker.urge).
    private var markerUrgent = false
    // debug
    /// -debugHUD text: two compact lines in the bottom-left corner.
    let debugLabel = GlyphLabel("", font: Fonts.mono, size: 9, color: UIPalette.teal, charset: GlyphLabel.debugCharset, align: .left, valign: .bottom,
                                multiline: true)
    var showDebug = false
    var visible = true { didSet { root.isHidden = !visible } }
    /// iOS Reduce Motion: banner shown longer (web 3.4 s instead of 2.4 s), no combo bump.
    var reducedMotion = false
    private var overlays: [SKSpriteNode] = []
    // per-frame text only rebuilt when its source changes (every new string renders a label texture)
    private var objKey = Int.min
    private var hintRaw = "\u{1}"
    private var timeSec = -1
    private var levelShown = -1

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
        objEdge.anchorPoint = CGPoint(x: 0, y: 1)
        objEdge.isHidden = true
        root.addChild(objEdge)
        root.addChild(objCap.node); root.addChild(objText.node); root.addChild(objBar.node)
        root.addChild(coachCard.node)
        for r in [abilityRing, dashRing, markerRing] { r.isHidden = true }
        markerRing.zPosition = -1
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
        abilityRing.texture = Shapes.glowRing(radius: abilityButton.radius, color: UIPalette.amber, lineWidth: 3, glow: 16, inner: true)
        abilityRing.size = abilityRing.texture?.size() ?? .zero
        dashRing.texture = Shapes.glowRing(radius: dashButton.radius, color: UIPalette.amber, lineWidth: 3, glow: 14, inner: true)
        dashRing.size = dashRing.texture?.size() ?? .zero
        abilityButton.node.addChild(abilityRing); abilityRing.zPosition = 2
        dashButton.node.addChild(dashRing); dashRing.zPosition = 2
        root.addChild(ghost.thumb)
        ghost.thumb.zPosition = 30
        vignette.texture = GeneratedTextures.vignette(edge: UIColor(red: 0.01, green: 0.02, blue: 0.04, alpha: 0.75), inner: 0.42)
        damage.texture = GeneratedTextures.vignette(edge: UIColor(red: 0.86, green: 0.04, blue: 0.04, alpha: 0.9), inner: 0.3)
        horde.texture = damage.texture
        vignette.zPosition = -20
        damage.zPosition = -19; damage.alpha = 0
        horde.zPosition = -18; horde.alpha = 0
        flash.zPosition = -17; flash.alpha = 0
        flash.blendMode = .add
        for n in [vignette, damage, horde, flash] { root.addChild(n) }
        overlays = [damage, flash, horde]
        plates.root.zPosition = -10
        root.addChild(plates.root)
        marker.addChild(markerArrow)
        markerRing.size = markerRing.texture?.size() ?? .zero
        marker.addChild(markerRing)
        markerLabel.node.position = CGPoint(x: 0, y: -22)
        marker.addChild(markerLabel.node)
        marker.isHidden = true
        root.addChild(marker)
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
            r.node.isHidden = true   // VX-5: shown only while that squadmate needs attention
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
        layoutGen += 1
        let W = size.width, H = size.height
        let landscape = W > H
        let sl = max(16, insets.left), sr = max(16, insets.right), st = insets.top, sb = insets.bottom
        let top = 10 + st

        // stats panel (top-left); the time column moves right when the kill count gets wide and the combo counter
        // sits inside the panel (web .hud-tl flex row)
        let statsH: CGFloat = landscape ? 40 : 44
        statsTop = top
        statsLeft = sl
        statsKillsW = -1
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
        objLayoutStatsRight = -1
        fitStats()

        // squad list (VX-5: rows only for squadmates who need attention, stacked under the top band each frame)
        let rowW: CGFloat = 117, rowH: CGFloat = 22
        for r in squad {
            r.panel.removeFromParent()
            r.panel = Shapes.panel(width: rowW, height: rowH, cut: 5)
            r.panel.zPosition = -1
            r.node.addChild(r.panel)
            r.panel.position = .zero
            r.chip.position = CGPoint(x: 1.5, y: -rowH / 2)
            r.name.node.position = CGPoint(x: 9, y: -rowH / 2)
            r.bar.node.position = CGPoint(x: rowW - 46, y: -rowH / 2)
        }
        squadShown = -1
        bandBottom = objBottom
        placeBand()

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

        // banner (VX-5 portrait: lower, under the trimmed HUD, top at 27 % + safe top; title clamp(24, 7.4 vw, 64))
        let bw = min(560, W * 0.86)
        banner.position = hp(W / 2, H * (landscape ? 0.24 : 0.27) + st + 40)
        bannerTitle.size = landscape ? max(30, min(64, W * 0.08)) : max(24, min(64, W * 0.074))
        bannerSub.kern = landscape ? 3.6 : 1.9
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

    private var statsTop: CGFloat = 0, statsLeft: CGFloat = 0, statsKillsW: CGFloat = -1, statsComboW: CGFloat = -1
    private var objLayoutStatsRight: CGFloat = -1

    /// Stats panel from the current kill-count and combo widths (web .hud-tl: kills, time, combo in one flex row;
    /// re-built only when a column moves by a 10 pt step).
    private func fitStats() {
        let landscape = size.width > size.height
        let kw = max(38, (killsVal.width / 10).rounded(.up) * 10)
        let cwid: CGFloat = comboLast >= 5 ? max(30, (comboVal.width / 10).rounded(.up) * 10) : 0
        if kw == statsKillsW && cwid == statsComboW { return }
        statsKillsW = kw
        statsComboW = cwid
        let statsH: CGFloat = landscape ? 40 : 44
        let timeX = 13 + kw + 13
        let timeW = max(48, timeVal.width)
        let statsW = max(landscape ? 124 : 130, timeX + timeW + (cwid > 0 ? 14 + cwid : 0) + 14)
        statsPanel.removeFromParent()
        statsPanel = Shapes.stretchedPanel(width: statsW, height: statsH, baseWidth: landscape ? 124 : 130)
        statsPanel.position = hp(statsLeft, statsTop)
        statsPanel.zPosition = -1
        root.addChild(statsPanel)
        timeCap.node.position = hp(statsLeft + timeX, statsTop + 12)
        timeVal.node.position = hp(statsLeft + timeX, statsTop + (landscape ? 29 : 31))
        comboVal.node.position = hp(statsLeft + timeX + timeW + 14, statsTop + statsH / 2 + 1)
        layoutObjective(statsRight: statsLeft + statsW)
    }

    /// Objective box: its own row in portrait; in landscape centred between the stats panel and the pause button,
    /// pushed right / narrowed so it never overlaps either (web .hud-obj flex item).
    private func layoutObjective(statsRight: CGFloat) {
        let W = size.width
        let landscape = W > size.height
        let sl = max(16, insets.left), sr = max(16, insets.right)
        let top = 10 + insets.top
        let statsH: CGFloat = landscape ? 40 : 44
        var objW: CGFloat, objX: CGFloat
        let objY: CGFloat
        if landscape {
            if statsRight == objLayoutStatsRight { return }
            objLayoutStatsRight = statsRight
            objW = min(480, W - sl - sr - 124 - 44 - 40)
            objX = max((W - objW) / 2, statsRight + 10)
            objW = max(160, min(objW, W - sr - 44 - 10 - objX))
            objY = top
        } else {
            if objLayoutStatsRight == 0 { return }
            objLayoutStatsRight = 0
            objW = W - sl - sr
            objX = sl
            objY = top + statsH + 8
        }
        // VX-5 portrait (≤ 600 pt): one line, no «ЗАДАЧА», 13 pt, ≈ 32 pt tall (web padding 5 / 10 / 6)
        objTrim = !landscape && W <= 600
        let objH: CGFloat = objTrim ? 32 : 46
        objRect = CGRect(x: objX, y: objY, width: objW, height: objH)
        objCap.node.isHidden = objTrim
        objText.size = objTrim ? 13 : (W <= 600 ? 14 : 16)
        objBar.resize(width: objW - (objTrim ? 20 : 32))
        objBar.node.position = hp(objX + (objTrim ? 10 : 16), objY + objH - (objTrim ? 6 : 5))
        objCap.node.position = hp(objX + objW / 2, objY + 11)
        placeObjText()
        objEdge.size = CGSize(width: 3, height: objH - 7)
        objEdge.position = hp(objX, objY)
        rebuildObjPanel()
        objBottom = objY + objH
        plates.topLimit = hp(0, objBottom + 4).y
    }

    /// The objective text: centred in the trimmed box (a little higher while the bar shows), under the caption else.
    private func placeObjText() {
        let r = objRect
        let y = objTrim ? (objBarShown ? r.minY + 13 : r.minY + r.height / 2) : r.minY + 27
        objText.node.position = hp(r.midX, y)
    }

    /// Panel texture of the current style (the converging box is filled dark red; one texture per height).
    private func rebuildObjPanel() {
        let r = objRect
        guard r.width > 0 else { return }
        objPanel.removeFromParent()
        objPanel = Shapes.stretchedPanel(width: r.width, height: r.height, baseWidth: 160,
                                         fill: objStyle == .converging ? UIPalette.redPanel : UIPalette.panel)
        objPanel.position = hp(r.minX, r.minY)
        objPanel.zPosition = -1
        root.addChild(objPanel)
    }

    /// v1.1 objective variants (web .obj-box.press1 / .press2 / .boss): edge, caption / text colours, bar, fill.
    private func applyObjStyle(_ st: ObjectiveStyle) {
        let was = objStyle
        objStyle = st
        switch st {
        case .normal:
            objEdge.isHidden = true
            objCap.color = UIPalette.amber
            objText.color = UIPalette.ink
            objBar.style(fill: UIPalette.teal, track: UIPalette.tealTrack)
        case .waking:
            objEdge.isHidden = false; objEdge.color = UIPalette.amber
            objCap.color = UIPalette.amber
            objText.color = UIPalette.amber
            objBar.style(fill: UIPalette.amber, track: UIPalette.amberTrack)
        case .converging:
            objEdge.isHidden = false; objEdge.color = UIPalette.red
            objCap.color = UIPalette.red
            objText.color = UIPalette.red
            objBar.style(fill: UIPalette.red, track: UIPalette.amberTrack)
        case .boss:
            objEdge.isHidden = false; objEdge.color = UIPalette.queen
            objCap.color = UIPalette.queen
            objText.color = UIPalette.ink
            objBar.style(fill: UIPalette.queen, track: UIPalette.queenTrack, texture: Shapes.hGradient(UIPalette.queen, UIPalette.red))
        }
        objBar.fill.alpha = 1
        if (was == .converging) != (st == .converging) { rebuildObjPanel() }
    }

    /// Squad alert rows and toasts start under the top band: the objective box, or the coach card while it shows.
    private func placeBand() {
        let landscape = size.width > size.height
        let sr = max(16, insets.right), top = 10 + insets.top
        toastRoot.position = hp(size.width - sr, landscape ? max(top + 52, bandBottom + 6) : bandBottom + 8)
        // the nameplates never rise above the band either (web plateTop = max(objective, coach card) bottom + 4)
        plates.topLimit = hp(0, bandBottom + 4).y
    }

    // ---------------------------------------------------------------- events
    func toast(_ text: String, kind: ToastKind) {
        let maxW = min(320, size.width * 0.6)
        let key = "\(Int(maxW))|" + text
        let label: SKLabelNode, lf: CGRect
        if let c = toastLabels[key], c.0.parent == nil {
            (label, lf) = c
        } else {
            label = Toast.makeLabel(text, maxWidth: maxW - 22)
            lf = label.frame
            // only wrapped ones are kept (single-line labels are cheap to make)
            if toastLabels[key] == nil && lf.height > 20 { toastLabels[key] = (label, lf) }
        }
        let t = Toast(label: label, frame: lf, kind: kind)
        let tf = t.labelFrame
        let w = min(maxW, max(80, tf.width + 22))
        t.height = max(26, tf.height + 12)
        t.panel = SKSpriteNode(color: UIPalette.panel, size: CGSize(width: w, height: t.height))
        t.panel.anchorPoint = CGPoint(x: 0, y: 1)
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
        // (not while warming up: every wrapped toast has to be drawn once behind the cover)
        if toasts.count > 4 && !warming { toasts[0].discard(); toasts.removeFirst() }
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
    private var warming = false
    /// Texts of the glyph labels that start empty (combo, marker distance), kept while the warm-up shows every glyph.
    private var warmTexts = ("", "")
    /// v1.1 warm-up: every new objective string in its colour and size, the panel variants, the hold hints, the revive
    /// lines, the coach card, the ghost thumb, the target rings and the urgent marker, drawn once behind the cover.
    private var warmNode: SKNode?
    private func warmV11(_ on: Bool) {
        warmNode?.removeFromParent()
        warmNode = nil
        // whatever the warm-up shows, the next update applies the game's real state again
        coachTarget = nil
        cardStep = -1
        markerUrgent = false
        marker.setScale(1)
        coachCard.hide()
        ghost.set(.none, at: .zero)
        abilityRing.isHidden = true; dashRing.isHidden = true; markerRing.isHidden = true
        markerArrow.texture = HUD.chevronAmber
        markerLabel.color = UIPalette.amber
        guard on else { return }
        let n = SKNode()
        let W = size.width
        var y: CGFloat = size.height / 2 - 140
        let objStrings: [(String, SKColor)] = [
            ("Улей просыпается — к маяку", UIPalette.amber), ("Рой стягивается — к маяку!", UIPalette.red),
            ("Улей просыпается — к лифту!", UIPalette.amber), ("Рой стягивается — к лифту!", UIPalette.red),
            ("Убейте Матку · лифт ждёт", UIPalette.ink), ("Лифт заблокирован — Матка жива", UIPalette.ink)]
        for (t, c) in objStrings {
            for sz in [13, 16] as [CGFloat] {
                let l = Label(t.uppercased(), font: Fonts.semibold, size: sz, color: c, kern: 0.6)
                l.node.position = CGPoint(x: 0, y: y)
                n.addChild(l.node)
                y -= 18
            }
        }
        for cap in [UIPalette.red, UIPalette.queen] {
            let l = Label("ЗАДАЧА", font: Fonts.medium, size: 12, color: cap, kern: 2.4)
            l.node.position = CGPoint(x: -W / 4, y: y); n.addChild(l.node); y -= 16
        }
        for (fill, edge) in [(UIPalette.panel, UIPalette.amber), (UIPalette.redPanel, UIPalette.red), (UIPalette.panel, UIPalette.queen)] {
            for h in [32, 46] as [CGFloat] {
                let pnl = Shapes.stretchedPanel(width: 220, height: h, baseWidth: 160, fill: fill)
                pnl.position = CGPoint(x: -110, y: y); n.addChild(pnl)
                let e = SKSpriteNode(color: edge, size: CGSize(width: 3, height: h - 7)); e.anchorPoint = CGPoint(x: 0, y: 1)
                e.position = CGPoint(x: -110, y: y); n.addChild(e)
                y -= h + 2
            }
        }
        let bars = [Bar(width: 180, height: 4, fill: UIPalette.amber, track: UIPalette.amberTrack),
                    Bar(width: 180, height: 4, fill: UIPalette.red, track: UIPalette.amberTrack),
                    Bar(width: 180, height: 4, fill: UIPalette.queen, track: UIPalette.queenTrack)]
        bars[2].style(fill: UIPalette.queen, track: UIPalette.queenTrack, texture: Shapes.hGradient(UIPalette.queen, UIPalette.red))
        for b in bars { b.set(0.6); b.node.position = CGPoint(x: -90, y: y); n.addChild(b.node); y -= 8 }
        var hints = Difficulty.tiers.map { Game.holdHintText($0) } + CoachText.reviveLines
        hints.append(contentsOf: ["Вы ранены — союзники идут на помощь", "Встаньте рядом с раненым, чтобы поднять его"])
        for t in hints {
            let l = Label(t.uppercased(), font: Fonts.semibold, size: 14, color: UIPalette.amber, kern: 1.1)
            l.node.position = CGPoint(x: 0, y: y); n.addChild(l.node); y -= 18
        }
        root.addChild(n)
        warmNode = n
        // the card with a two-line text, the thumb, the rings, the red marker
        coachCard.show(step: 1, text: CoachText.text(step: 1, abilityShort: "Граната", keyboard: false).uppercased(), centerX: 0,
                       top: hp(0, objBottom + 2).y, maxWidth: min(W * 0.92, 520))
        ghost.set(.drag, at: stickRestL)
        abilityRing.isHidden = false; dashRing.isHidden = false; markerRing.isHidden = false
        markerArrow.texture = HUD.chevronRed
        markerLabel.color = UIPalette.red
    }

    func warmUp(_ on: Bool) {
        warming = on
        warmV11(on)
        if on {
            // every glyph atlas drawn once (an atlas texture is uploaded on its first draw; these two start empty)
            warmTexts = (comboVal.text, markerLabel.text)
            comboVal.set("×" + GlyphLabel.digits)
            markerLabel.set(GlyphLabel.digits + " м")
            screenFlash(0.6); damageFlash(0.8); hordeFlash()
            showBanner(title: "ОРДА!", subtitle: "РОЙ ПРОРЫВАЕТСЯ ИЗ БЕЗДНЫ", teal: false)
            toast("Связь установлена", kind: .info)
            // every wrapped toast of a mission, so its label exists before the mission needs it
            for (k, spec) in BUG_SPECS.enumerated() where k < BUG_TIPS.count && !BUG_TIPS[k].isEmpty {
                toast(spec.name + ": " + BUG_TIPS[k], kind: .warn)
            }
            toast("Вы ранены — ждите помощи", kind: .warn)
            abilityButton.update(ready: false, fraction: 0.5)
            dashButton.update(ready: false, fraction: 0.5)
            abilityButton.warmPies(true)
            dashButton.warmPies(true)
            marker.isHidden = false
            damage.alpha = 0.5; flash.alpha = 0.3; horde.alpha = 0.5; banner.alpha = 1
        } else {
            damageA = 0; flashA = 0; hordeA = 0
            damage.alpha = 0; flash.alpha = 0; horde.alpha = 0
            bannerT = 99; banner.alpha = 0
            for t in toasts { t.discard() }
            toasts.removeAll()
            comboVal.set(warmTexts.0)
            markerLabel.set(warmTexts.1)
            abilityButton.update(ready: true, fraction: 0)
            dashButton.update(ready: true, fraction: 0)
            abilityButton.warmPies(false)
            dashButton.warmPies(false)
        }
    }

    func damageFlash(_ a: Float) { damageA = min(1, damageA + a) }
    func screenFlash(_ a: Float) { flashA = max(flashA, a) }
    func hordeFlash() { hordeA = 1 }

    /// HUD point inside the pause button?
    func pauseHit(viewPoint p: CGPoint) -> Bool { pauseRect.contains(p) }

    /// HUD point on the coach card's «Пропустить»?
    func coachSkipHit(_ p: CGPoint) -> Bool { !root.isHidden && coachCard.contains(p) }

    // ---------------------------------------------------------------- per frame
    /// `keyboard`: the last input was a hardware keyboard (the coach names keys, no ghost thumb).
    func update(game: Game, dt: Float, projection: HUDProjection, input: InputController, keyboard: Bool = false) {
        let P = game.player
        // fast-changing numbers at 10 Hz (glyph labels: a new value only re-points sprites)
        textT -= dt
        if textT <= 0 {
            textT = 0.1
            killsVal.set("\(game.kills)")
            hpVal.set("\(Int(max(0, P.hp).rounded(.up)))")
            let combo = game.comboShown
            if combo != comboLast {
                comboVal.set(combo > 0 ? "×\(combo)" : "")
                // web .combo.hot (≥ 25) / .blaze (≥ 60), and a short scale bump per new combo kill
                comboVal.color = combo >= 60 ? UIPalette.white : (combo >= 25 ? UIPalette.red : UIPalette.amber)
                let now = FrameTimer.now()
                if combo >= 5 && !reducedMotion && now - comboBumpT > 0.07 {
                    comboBumpT = now
                    let big = combo / 25 != comboLast / 25
                    comboVal.node.removeAction(forKey: "bump")
                    comboVal.node.setScale(big ? 1.9 : 1.35)
                    let a = SKAction.scale(to: 1, duration: big ? 0.38 : 0.16)
                    a.timingMode = .easeOut
                    comboVal.node.run(a, withKey: "bump")
                }
                comboLast = combo
            }
            fitStats()
        }
        let sec = Int(max(0, game.time))
        if sec != timeSec { timeSec = sec; timeVal.set(formatTime(game.time)) }
        let ok = objectiveKey(game)
        if ok != objKey {
            objKey = ok
            let st = game.objectiveStyle
            if st != objStyle { applyObjStyle(st) }
            objText.set(game.objectiveText.uppercased())
        }
        let prog = game.objectiveProgress
        if (prog >= 0) != objBarShown { objBarShown = prog >= 0; placeObjText() }
        objBar.node.isHidden = prog < 0
        objBar.set(CGFloat(max(0, prog)))
        // the converging bar throbs 1 ↔ 0.45 every 0.6 s (web thr-throb; none with Reduce Motion)
        if objStyle == .converging && !reducedMotion {
            objBar.fill.alpha = CGFloat(0.725 + 0.275 * cos(FrameTimer.now() * .pi / 0.6))
        }
        updateCoach(game, keyboard: keyboard)
        // contextual hint (the control hint during the first 7 s is the app's job, not while the coach runs)
        var h = ""
        var urgent = false
        if let c = game.contextHint { h = c.text; urgent = c.urgent } else if game.showControlHint && !P.downed { h = "Левый палец — бег · правый — прицел и огонь" }
        if h != hintRaw { hintRaw = h; hint.set(h.uppercased()) }
        if urgent != hintUrgent { hintUrgent = urgent; hint.color = urgent ? UIPalette.red : UIPalette.amber }
        hint.node.alpha = urgent ? (sinf(game.time * 7.85) > 0 ? 1 : 0.35) : 1

        // VX-5: a squadmate's row only while downed, under 35 % armour, or with its plate off screen / under the top band
        var shown = 0
        let halfW = size.width / 2, halfH = size.height / 2, bandY = hp(0, bandBottom + 4).y
        for (k, r) in squad.enumerated() where k < game.marines.count {
            let m = game.marines[k]
            var alert = false
            if k > 0 {
                if m.downed || m.hp < m.maxHp * 0.35 { alert = true } else {
                    let f = projection.feet(k)
                    let a = projection.hudPoint(f.0, f.1 + 2.55, f.2)
                    alert = a.x < -halfW || a.x > halfW || a.y > bandY || a.y < -halfH
                }
            }
            if alert { shown |= 1 << k }
            if !alert { continue }
            r.bar.set(CGFloat(m.hp / max(1, m.maxHp)))
            r.name.color = m.downed ? UIPalette.red : UIPalette.ink
            r.name.node.alpha = m.downed && sinf(game.time * 10.5) < 0 ? 0.3 : 1
        }
        if shown != squadShown || bandBottom != squadBand {
            squadShown = shown
            squadBand = bandBottom
            let landscape = size.width > size.height
            let top0 = landscape ? 10 + insets.top + 40 + 8 : bandBottom + 8
            var y = top0
            for (k, r) in squad.enumerated() {
                let on = shown & (1 << k) != 0
                r.node.isHidden = !on
                if on { r.node.position = hp(max(16, insets.left), y); y += 26 }
            }
        }
        hpBar.set(CGFloat(P.hp / max(1, P.maxHp)))
        if game.xpLevel != levelShown { levelShown = game.xpLevel; lvl.set("УР \(game.xpLevel)") }
        xpBar.set(CGFloat(Float(game.xp) / Float(max(1, game.xpNext))))

        abilityButton.update(ready: P.abilityReady, fraction: CGFloat(P.abilityCooldownFraction))
        dashButton.update(ready: P.dashReady, fraction: CGFloat(P.dashCooldownFraction))

        // sticks
        if let l = input.left {
            stickL.active(origin: hp(l.origin.x, l.origin.y), knob: input.knobOffset(l))
        } else {
            stickL.idle(at: stickRestL, learned: sticksLearned)
        }
        if let r = input.right {
            stickR.active(origin: hp(r.origin.x, r.origin.y), knob: input.knobOffset(r))
        } else {
            stickR.idle(at: stickRestR, learned: sticksLearned)
        }

        // toasts
        var y: CGFloat = 0
        var k = 0
        while k < toasts.count {
            let t = toasts[k]
            t.t += dt
            if t.t >= t.life { t.discard(); toasts.remove(at: k); continue }
            let u = t.t / t.life
            t.node.alpha = CGFloat(u < 0.08 ? u / 0.08 : (u > 0.85 ? (1 - u) / 0.15 : 1))
            t.node.position = CGPoint(x: u < 0.08 ? CGFloat((1 - u / 0.08) * 20) : 0, y: y)
            y -= t.height + 4
            k += 1
        }
        // banner (2.4 s, 3.4 s with Reduce Motion)
        bannerT += dt
        let bannerDur: Float = reducedMotion ? 3.4 : 2.4
        if bannerT < bannerDur {
            let u = bannerT / bannerDur
            var a: Float = 1
            if u < 0.08 { a = u / 0.08 } else if u < 0.15 { a = 1 - (u - 0.08) / 0.07 * 0.25 } else if u < 0.22 { a = 0.75 + (u - 0.15) / 0.07 * 0.25 } else if u > 0.8 { a = (1 - u) / 0.2 }
            banner.alpha = CGFloat(a)
            banner.setScale(CGFloat(u < 0.08 ? 1.25 - u / 0.08 * 0.25 : (u > 0.8 ? 1 - (u - 0.8) / 0.2 * 0.02 : 1)))
        } else if banner.alpha > 0 {
            banner.alpha = 0
        }
        // overlays (web updateHUD: the red vignette = max(damage flash, low armour pulse, 0.5 while downed))
        damageA = max(0, damageA - dt * 1.6)
        flashA = max(0, flashA - dt * 3)
        hordeA = max(0, hordeA - dt * 0.4)
        let wall = Float(FrameTimer.now().truncatingRemainder(dividingBy: 1000))
        let low: Float = !P.downed && P.hp < P.maxHp * 0.3 ? 0.35 + 0.15 * sinf(wall * 6.25) : 0
        damage.alpha = CGFloat(min(1, max(damageA, low, P.downed ? 0.5 : 0)))
        flash.alpha = CGFloat(flashA * 0.45)
        // VX-5: the horde glow peaks at 0.7 on a phone screen
        horde.alpha = CGFloat(hordeA * (0.6 + 0.4 * sinf(wall * 11.1)) * 0.7)
        // full-screen quads: skip the fill entirely while invisible
        for n in overlays { n.isHidden = n.alpha < 0.004 }
        banner.isHidden = banner.alpha < 0.004

        plates.update(game: game, projection: projection, size: size)
        updateMarker(game: game, projection: projection)
    }

    /// Changes whenever objectiveText / objectiveStyle would (stage, active beacon, beacons done, threat state, the lift
    /// lock, lift countdown second).
    private func objectiveKey(_ g: Game) -> Int {
        if g.attract { return -1 }
        let st: Int
        switch g.stage {
        case .beacons: st = 1
        case .toLift: st = 2
        case .hold: st = 3
        case .extract: st = 4
        }
        let lift = st == 3 ? Int(g.liftT.rounded(.up)) : 0
        let threat = g.threatState.rawValue, locked = g.liftLocked ? 1 : 0
        return ((((st * 16 + (g.activeBeacon + 1)) * 16 + g.beaconsDone) * 4 + threat) * 2 + locked) * 100_000 + lift
    }

    private var squadShown = -1
    private var squadBand: CGFloat = -1

    /// «Учебная высадка»: the card for the current step (touch or keyboard text), under it the alerts and toasts; the
    /// ghost thumb on the control of the step, its target pulsing (wall time; slower with Reduce Motion).
    private func updateCoach(_ game: Game, keyboard: Bool) {
        coachCard.reducedMotion = reducedMotion
        ghost.reducedMotion = reducedMotion
        let target = warming ? nil : game.coach.target
        let W = size.width
        if let t = target {
            let step = game.coach.step
            let top = objBottom + 2
            // the card text is built only when the step, the input mode or the layout changes (no per-frame strings)
            if step != cardStep || keyboard != cardKeyboard || layoutGen != cardLayoutGen || !coachCard.visible {
                cardStep = step; cardKeyboard = keyboard; cardLayoutGen = layoutGen
                let text = CoachText.text(step: step, abilityShort: game.player.spec.abilityShort, keyboard: keyboard).uppercased()
                coachCard.show(step: step, text: text, centerX: 0, top: hp(0, top).y, maxWidth: min(W * 0.92, 520))
            }
            coachCard.update(top: hp(0, top).y)
            let bb = top + coachCard.height
            if bb != bandBottom { bandBottom = bb; placeBand() }
            if t != coachTarget || keyboard != coachKeyboard {
                coachTarget = t
                coachKeyboard = keyboard
                switch t {
                case .moveStick: ghost.set(keyboard ? .none : .drag, at: stickRestL)
                case .aimStick: ghost.set(keyboard ? .none : .drag, at: stickRestR)
                case .ability: ghost.set(keyboard ? .none : .tap, at: abilityButton.node.position)
                case .dash: ghost.set(keyboard ? .none : .tap, at: dashButton.node.position)
                case .objective: ghost.set(.none, at: .zero)
                }
                abilityRing.isHidden = t != .ability
                dashRing.isHidden = t != .dash
                markerRing.isHidden = t != .objective
            }
            ghost.update()
            // target pulses: the button ring 0.15 ↔ 1 (0.9 s), the marker ring 0.8 ↔ 1.15 with 0.2 ↔ 1
            let p = ghost.pulse(0.9)
            if t == .ability { abilityRing.alpha = 0.15 + 0.85 * p }
            if t == .dash { dashRing.alpha = 0.15 + 0.85 * p }
            if t == .objective { markerRing.alpha = 0.2 + 0.8 * p; markerRing.setScale(0.8 + 0.35 * p) }
        } else if coachTarget != nil || coachCard.visible {
            if !warming {
                coachTarget = nil
                coachCard.hide()
                ghost.set(.none, at: .zero)
                abilityRing.isHidden = true; dashRing.isHidden = true; markerRing.isHidden = true
                if bandBottom != objBottom { bandBottom = objBottom; placeBand() }
            }
        }
    }
    private var coachKeyboard = false
    private var cardStep = -1, cardKeyboard = false, cardLayoutGen = -1
    /// Bumped by every layout (rotation, safe area): the coach card is laid out again.
    private var layoutGen = 0

    /// Metres last written into the marker label (the string is only formatted when it changes).
    private var markerDist = -1

    private func updateMarker(game: Game, projection: HUDProjection) {
        guard let t = game.objectiveMarker else { marker.isHidden = true; return }
        marker.isHidden = false
        let urgent = game.markerUrgent
        if urgent != markerUrgent {
            markerUrgent = urgent
            markerArrow.texture = urgent ? HUD.chevronRed : HUD.chevronAmber
            markerLabel.color = urgent ? UIPalette.red : UIPalette.amber
            if !urgent { marker.setScale(1) }
        }
        // web thr-urge: 1 ↔ 1.3 every 0.6 s (none with Reduce Motion)
        if urgent && !reducedMotion { marker.setScale(1.15 - 0.15 * CGFloat(cos(FrameTimer.now() * .pi / 0.6))) }
        let gy = game.level.groundY(t.x, t.y)
        let s = projection.hudPoint(t.x, gy + 1.2, t.y)
        let P = game.player
        let dist = hypotf(t.x - P.x, t.y - P.z)
        let dm = Int(dist.rounded())
        if dm != markerDist { markerDist = dm; markerLabel.set("\(dm) м") }
        let mx = size.width / 2 - 40, myTop = size.height / 2 - bandBottom - 30, myBot = -size.height / 2 + 150
        // VX-5: the block holding РЫВОК and the ability button (+ 20 pt): an on-screen marker there counts as off screen,
        // an edge arrow that would land in it stops where its ray enters it (web mkBlockX / mkBlockY)
        let ar = abilityButton.radius, dr = dashButton.radius
        let blockX = min(abilityButton.node.position.x - ar, dashButton.node.position.x - dr) - 20
        let blockTop = max(abilityButton.node.position.y + ar, dashButton.node.position.y + dr) + 20
        let inside = abs(s.x) < mx && s.y < myTop && s.y > myBot && !(s.x > blockX && s.y < blockTop)
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
            if dx * k > blockX && dy * k < blockTop {
                var ke: CGFloat = 0
                if blockX > 0 && dx > 1e-4 { ke = blockX / dx }
                if blockTop < 0 && dy < -1e-4 { ke = max(ke, blockTop / dy) }
                k = ke
            }
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
        let seg: DashBar?
        let revive = SKSpriteNode(color: UIPalette.teal, size: CGSize(width: 76, height: 2))
        init(name text: String, player: Bool) {
            let w: CGFloat = player ? 96 : 76
            name = Label(text, font: player ? Fonts.semibold : Fonts.medium, size: 12, color: player ? UIPalette.white : UIPalette.ink, kern: 1.2)
            bar = Bar(width: w, height: 4, fill: UIPalette.hp, track: UIPalette.hpBg, topLine: UIPalette.teal)
            seg = player ? DashBar(width: w, height: 3, color: UIPalette.rgba(219, 230, 238, 0.8)) : nil
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

    func update(game: Game, projection: HUDProjection, size: CGSize) {
        let n = min(plates.count, game.marines.count)
        for k in 0..<n {
            let m = game.marines[k]
            let f = projection.feet(k)
            let s = projection.hudPoint(f.0, f.1 + (m.downed ? 1.3 : 2.55), f.2)
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
        // a bot plate drawn over the player's own marine fades so the player stays visible (web .plate.dim)
        var meX: CGFloat = -1e4, meY: CGFloat = -1e4
        if n > 0 {
            let f = projection.feet(0)
            let me = projection.hudPoint(f.0, f.1 + 1.0, f.2)
            meX = me.x; meY = me.y
        }
        for k in 0..<n {
            let m = game.marines[k], p = plates[k]
            let x = max(-halfW + 40, min(halfW - 40, px[k]))
            p.node.position = CGPoint(x: x, y: py[k])
            // HUD y is up: the plate spans py − 28 … py + 4 around its anchor in web terms (top-down)
            let dim = k > 0 && abs(meX - x) < 40 && meY < py[k] + 4 && meY > py[k] - 28
            let a: CGFloat = dim ? 0.7 : 1
            if p.node.alpha != a { p.node.alpha = a }
            p.bar.set(CGFloat(m.hp / max(1, m.maxHp)))
            p.seg?.set(CGFloat(m.bar))
            if let s = p.seg { s.node.alpha = (m.overheated || m.reloading) ? (sinf(game.time * 18) > 0 ? 1 : 0.2) : 0.8 }
            p.name.color = m.downed ? UIPalette.red : (m.isPlayer ? UIPalette.white : UIPalette.ink)
            p.revive.xScale = max(0.0001, CGFloat(m.downed ? m.revive : 0))
            p.revive.isHidden = !m.downed
        }
    }
}
