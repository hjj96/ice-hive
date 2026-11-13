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
        TextFit.scale(label, labelRoom(radius))
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

    /// The label's widest inside the disc (a chord 6 pt in from the rim on each side).
    func labelRoom(_ r: CGFloat) -> CGFloat { 2 * r - 12 }

    /// A new label (the player's ability), scaled down to fit the disc.
    func setLabel(_ t: String) {
        label.set(t)
        TextFit.scale(label, labelRoom(radius))
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

    /// The caption's size (the layout check).
    var captionSize: CGSize { CGSize(width: caption.width, height: 14) }

    func active(origin: CGPoint, knob offset: CGPoint) {
        node.position = origin
        knob.position = offset
        node.alpha = 1
        caption.node.isHidden = true
    }
}

// ================================================================
//  HUD — the in-game overlay (camera child), laid out like the web
//  #hud / #touchUI on a landscape phone (the app is landscape-only).
//  Top row: stats · objective · pause; under it the squad alerts
//  (left), the coach card (centre), the toasts (right column, never
//  down into the dash button). Bottom: the armour block in the centre,
//  the move ring on the left, the aim ring on the right with the dash
//  (above) and ability (below) buttons in an arc at the right edge,
//  the hint between the rings just above the armour block.
// ================================================================
final class HUD {
    let root = SKNode()
    private(set) var size = CGSize(width: 874, height: 402)
    private var insets = UIEdgeInsets.zero

    // top row
    private var statsPanel = SKSpriteNode(texture: nil)
    private let killsCap = Label(L10n.upper(L10n.ui(.hudKills)), font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 1.4, align: .left)
    private let timeCap = Label(L10n.upper(L10n.ui(.hudTime)), font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 1.4, align: .left)
    // numbers that change every few frames: glyph-atlas labels (no text texture per new value)
    private let killsVal = GlyphLabel("0", font: Fonts.monoBold, size: 17, color: UIPalette.ink, charset: GlyphLabel.digits + ",", align: .left)
    private let timeVal = GlyphLabel("0:00", font: Fonts.monoBold, size: 17, color: UIPalette.ink, charset: GlyphLabel.digits + ":", align: .left)
    /// The combo counter's characters: digits + whatever hud.combo («×%lld») adds.
    private static let comboCharset = L10n.charset([L10n.ui(.hudCombo, .int(0))])
    private let comboVal = GlyphLabel("", font: Fonts.monoBold, size: 16, color: UIPalette.amber, charset: HUD.comboCharset, align: .left)
    private var comboLast = 0
    private var comboBumpT: Double = 0
    private var tealEdge = SKSpriteNode(color: UIPalette.teal, size: CGSize(width: 3, height: 44))
    private var pausePanel = SKSpriteNode(texture: nil)
    private let pauseBars = SKNode()
    private var pauseRect = CGRect.zero
    // objective
    private var objPanel = SKSpriteNode(texture: nil)
    private let objCap = Label(L10n.upper(L10n.ui(.hudObjective)), font: Fonts.medium, size: 12, color: UIPalette.amber, kern: 2.4)
    private let objText = Label("—", font: Fonts.semibold, size: 16, color: UIPalette.ink, kern: 0.6)
    private let objBar = Bar(width: 200, height: 4, fill: UIPalette.teal, track: UIPalette.tealTrack)
    private var objBottom: CGFloat = 0
    // v1.1: threat variants of the objective box (waking amber, converging red, the Матка violet) — left edge, colours,
    // the converging fill
    private let objEdge = SKSpriteNode(color: UIPalette.amber, size: CGSize(width: 3, height: 39))
    private var objStyle: ObjectiveStyle = .normal
    /// Stage 2 B3: the boss bar's name — in the boss style the box's caption is the boss's name (the catalog's
    /// `name.bug.<kind>`, uppercased like the caption) over its bar; «OBJECTIVE» in every other style (nil).
    private var objCapName: NameRef? = nil
    private var objRect = CGRect.zero   // x, y = top-left in view points (y down), size
    private var statsRect = CGRect.zero
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
        var width: CGFloat = 80
        /// H1: its lane (ToastQueue), its column (the left one, mirrored, or the right one), seconds left of a quick
        /// fade-out (replaced by a newer bark, pushed out of a full column; < 0: none).
        let lane: ToastQueue.Lane
        let left: Bool
        var going: Float = -1
        init(label: SKLabelNode, frame: CGRect, life: Float, lane: ToastQueue.Lane, left: Bool) {
            self.label = label
            labelFrame = frame
            self.life = life
            self.lane = lane
            self.left = left
            panel = SKSpriteNode(texture: nil)
        }

        /// Off screen; the label is let go too (a cached one is reused by a later toast).
        func discard() {
            node.removeFromParent()
            label.removeFromParent()
        }

        /// The toast's text, wrapped at `maxWidth`: right-aligned in the right column, left-aligned in the left one.
        static func makeLabel(_ text: String, maxWidth: CGFloat, left: Bool = false) -> SKLabelNode {
            let label = SKLabelNode()
            let style = NSMutableParagraphStyle()
            style.alignment = left ? .left : .right
            label.numberOfLines = 0
            label.preferredMaxLayoutWidth = maxWidth
            label.horizontalAlignmentMode = left ? .left : .right
            label.verticalAlignmentMode = .top
            label.attributedText = NSAttributedString(string: L10n.upper(text), attributes: [
                .font: Fonts.font(Fonts.medium, 12), .foregroundColor: UIPalette.ink, .kern: CGFloat(1.0), .paragraphStyle: style])
            LabelStats.textsSet += 1
            return label
        }
    }
    /// Wrapped (two-line) toast labels, made once behind the loading cover and reused: making one mid-mission renders
    /// its text there and then, and CI saw that wait 1.5–9 s for the GPU during host stalls. Keyed by text, width and column.
    private var toastLabels: [String: (SKLabelNode, CGRect)] = [:]
    private var toasts: [Toast] = []
    /// The right column (under the top band at the right safe edge) and, H1, the left one (under the stats and the squad
    /// rows at the left safe edge): a toast goes to the side where it covers least of what matters (`toastSide`).
    private let toastRoot = SKNode()
    private let toastRootL = SKNode()
    /// H1: when the game's toasts show — one tip at a time, threats first, barks briefly, nothing new under a banner.
    let toastQueue = ToastQueue()
    /// The columns' alpha (0: stepped aside under a banner that covers them; their toasts' clocks stop meanwhile).
    private var toastColA: (r: CGFloat, l: CGFloat) = (1, 1)
    /// Top (view y) and floor (HUD y) of the left column: under the visible squad rows; above the move ring.
    private var toastTopL: CGFloat = 0
    private var toastFloorL: CGFloat = -1e6
    private let hint = Label("", font: Fonts.semibold, size: 14, color: UIPalette.amber, kern: 1.1)
    /// Second line of a hint wider than its gap (web #hHint wraps between the stick rings in landscape): the v1.1
    /// hold hints are ~450 pt, the revive lines ~370 pt. Two single-line labels, no wrapped label (TextWarmup), same
    /// style as the first line.
    private let hint2 = Label("", font: Fonts.semibold, size: 14, color: UIPalette.amber, kern: 1.1)
    private var hintUrgent = false
    /// Uppercased hint text, the widest a line may be, the bottom line's centre and whether a second line goes above
    /// it (the web anchors the landscape hint at its bottom).
    private var hintText = ""
    private var hintMaxW: CGFloat = 360
    /// The gap between the stick rings (HUD x of its left / right ends): the hint sits over the armour block (the
    /// screen centre) when its lines fit there with 12 pt to each ring, else as close to it as they do.
    private var hintGap: (CGFloat, CGFloat) = (-180, 180)
    private var hintBase = CGPoint.zero
    private var hintUp = false
    /// The fitted hint's widest line (unscaled) and its bottom line's centre at the bottom place (H1: `placeHint`).
    private var hintWidest: CGFloat = 0
    private var hintBottomBase = CGPoint.zero
    /// The hint's alpha while a banner over it is up (H1: 0 = stepped aside).
    private var hintAside: CGFloat = 1
    private let banner = SKNode()
    private let bannerTitle = Label("", font: Fonts.bold, size: 34, color: UIPalette.red, kern: 4)
    private let bannerSub = Label("", font: Fonts.medium, size: 12, color: UIPalette.ink, kern: 3.6)
    private let bannerBand = SKSpriteNode(color: UIPalette.bannerRed, size: CGSize(width: 400, height: 52))
    private var bannerStripes: [SKSpriteNode] = []
    private var bannerT: Float = 99
    private var textT: Float = 0
    // bottom
    private let hpCap = Label(L10n.upper(L10n.ui(.hudArmor)), font: Fonts.medium, size: 12, color: UIPalette.inkDim, kern: 1.4, align: .left)
    private let hpVal = GlyphLabel("100", font: Fonts.monoBold, size: 13, color: UIPalette.ink, charset: GlyphLabel.digits, align: .right)
    private let hpBar = Bar(width: 228, height: 9, fill: UIPalette.hp, track: UIPalette.hpBg, topLine: UIPalette.teal, topHeight: 2)
    /// The level label's characters: digits + the letters of hud.level («LVL %lld») — the atlas follows the catalog.
    private static let levelCharset = L10n.charset([L10n.upper(L10n.ui(.hudLevel, .int(0)))])
    private let lvl = GlyphLabel(L10n.upper(L10n.ui(.hudLevel, .int(1))), font: Fonts.monoBold, size: 12, color: UIPalette.amber,
                                 charset: HUD.levelCharset, align: .left)
    private let xpBar = Bar(width: 190, height: 3, fill: UIPalette.amber, track: UIPalette.amberTrack)
    // touch controls
    let abilityButton = RoundButton(radius: 39, text: L10n.upper(L10n.name(.abilityShort(.assault))))
    let dashButton = RoundButton(radius: 31, text: L10n.upper(L10n.ui(.hudDash)))
    let stickL = StickView(fire: false, caption: L10n.upper(L10n.ui(.hudMove)))
    let stickR = StickView(fire: true, caption: L10n.upper(L10n.ui(.hudFire)))
    private(set) var stickRestL = CGPoint.zero
    private(set) var stickRestR = CGPoint.zero
    // overlays
    private let vignette = SKSpriteNode(texture: nil)
    private let damage = SKSpriteNode(texture: nil)
    private let horde = SKSpriteNode(texture: nil)
    private let flash = SKSpriteNode(color: UIPalette.rgba(255, 240, 220, 1), size: CGSize(width: 10, height: 10))
    private var damageA: Float = 0, flashA: Float = 0, hordeA: Float = 0
    /// A menu covers the HUD (GameScene: paused, level-up, ended): no hint, no toasts.
    var covered = false
    // nameplates + objective marker
    let plates = Nameplates()
    private let marker = SKNode()
    private let markerArrow = SKSpriteNode(texture: Shapes.chevron(color: UIPalette.amber))
    /// The marker distance's characters: digits + hud.distance («%lld m»).
    private static let markerCharset = L10n.charset([L10n.ui(.hudDistance, .int(0))])
    private let markerLabel = GlyphLabel("", font: Fonts.monoBold, size: 12, color: UIPalette.amber, charset: HUD.markerCharset)
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
    /// What the hint shows (a core line, the app's control hint, or nothing): resolved only when it changes.
    private enum HintSource: Equatable { case none, controls, text(GameText) }
    private var hintSource = HintSource.text(GameText(.coachSkip))
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
        root.addChild(toastRootL)
        if AppLog.diagnostics { toastQueue.log = { AppLog.info("hud tip: " + $0) } }
        root.addChild(hint.node)
        root.addChild(hint2.node)
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
        // a new mission: no toast, queued tip or banner placement carries over (H1)
        for t in toasts { t.discard() }
        toasts.removeAll()
        toastQueue.reset()
        bannerSlot = .mid
        hintAtTop = false
        hintTopBottom = 0
        for r in squad { r.node.removeFromParent() }
        squad = marines.map { m in
            let r = SquadRow(name: L10n.upper(L10n.name(m.name)))
            TextFit.scale(r.name, HUD.squadNameRoom)
            r.node.isHidden = true   // VX-5: shown only while that squadmate needs attention
            r.chip.color = UIPalette.classColors[m.cls.rawValue]
            r.node.addChild(r.panel); r.node.addChild(r.chip); r.node.addChild(r.name.node); r.node.addChild(r.bar.node)
            root.addChild(r.node)
            return r
        }
        if let p = marines.first {
            abilityButton.setLabel(L10n.upper(L10n.name(.abilityShort(p.cls))))
        }
        plates.setSquad(marines)
        layout(size: size, insets: insets)
    }

    // ---------------------------------------------------------------- layout
    /// Landscape HUD geometry (LAND: the app is landscape-only, this is the one layout), view points (y down) from the
    /// bottom safe edge `bottom` = H − safe bottom − 8 and the right / left safe edges.
    enum Geo {
        /// Stick rings: centre `ringLift` above the bottom safe edge (their circles end above the armour block);
        /// the move ring `ringInL` in from the left safe edge, the aim ring `ringInR` in from the right one.
        static let ringLift: CGFloat = 124, ringInL: CGFloat = 100, ringInR: CGFloat = 168, ringR: CGFloat = 62
        /// The right thumb's arc around the aim ring: dash above-right, ability below-right (centres from the
        /// right / bottom safe edges).
        static let dashIn: CGFloat = 64, dashUp: CGFloat = 176, abilityIn: CGFloat = 50, abilityUp: CGFloat = 78
        /// Armour block: caption + bar + level row, ending 8 pt above the bottom safe edge.
        static let armourH: CGFloat = 46
        /// Squad alert rows (left column under the stats), toasts (right column under the band).
        static let rowW: CGFloat = 117, rowH: CGFloat = 22, rowStep: CGFloat = 26
    }

    /// A squad row's name ends 4 pt before its armour bar (9 pt in from the row's left, the bar 46 pt from its right).
    static let squadNameRoom: CGFloat = Geo.rowW - 9 - 46 - 4
    /// The objective text's widest (12 pt in from the box on each side) and how far it may shrink to fit.
    private var objTextRoom: CGFloat { objRect.width - 24 }
    static let objMinScale: CGFloat = 0.62

    func layout(size: CGSize, insets: UIEdgeInsets) {
        self.size = size
        self.insets = insets
        layoutGen += 1
        let W = size.width, H = size.height
        let sl = max(16, insets.left), sr = max(16, insets.right), st = insets.top, sb = insets.bottom
        let top = 10 + st

        // stats panel (top-left); the time column moves right when the kill count gets wide and the combo counter
        // sits inside the panel (web .hud-tl flex row)
        let statsH: CGFloat = 40
        statsTop = top
        statsLeft = sl
        statsKillsW = -1
        tealEdge.size = CGSize(width: 3, height: statsH)
        tealEdge.anchorPoint = CGPoint(x: 0, y: 1)
        tealEdge.position = hp(sl, top)
        killsCap.node.position = hp(sl + 13, top + 12)
        killsVal.node.position = hp(sl + 13, top + 29)

        // pause button (top-right)
        pausePanel.removeFromParent()
        pausePanel = Shapes.panel(width: 44, height: 44, stroke: UIPalette.lineStrong)
        pausePanel.position = hp(W - sr - 44, top)
        pausePanel.zPosition = -1
        root.addChild(pausePanel)
        pauseBars.position = hp(W - sr - 22, top + 22)
        pauseRect = CGRect(x: W - sr - 52, y: top - 8, width: 60, height: 60)

        // objective box between the stats and the pause button
        objLayoutStatsRight = -1
        fitStats()

        // squad list (VX-5: rows only for squadmates who need attention, stacked under the stats panel)
        let rowW = Geo.rowW, rowH = Geo.rowH
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

        // bottom: armour + level, centred
        let boxW = min(260, W * 0.32)
        let bottom = H - 8 - sb
        let bx = (W - boxW) / 2
        armourRect = CGRect(x: bx, y: bottom - Geo.armourH, width: boxW, height: Geo.armourH)
        lvl.node.position = hp(bx, bottom - 6)
        // the XP bar starts 6 pt after the widest level label («LVL 99» in the catalog's words)
        let lvW = max(38, (TextFit.width(L10n.upper(L10n.ui(.hudLevel, .int(99))), font: Fonts.monoBold, size: 12) + 6).rounded(.up))
        xpBar.resize(width: boxW - lvW)
        xpBar.node.position = hp(bx + lvW, bottom - 6)
        hpBar.resize(width: boxW)
        hpBar.node.position = hp(bx, bottom - 12 - 6 - 4.5)
        hpCap.node.position = hp(bx, bottom - 12 - 6 - 9 - 4 - 8)
        hpVal.node.position = hp(bx + boxW, bottom - 12 - 6 - 9 - 4 - 8)

        // stick rest positions: both rings at thumb height, their circles above the armour block; the right thumb's
        // buttons in an arc round the aim ring at the right edge (dash above, the ability below)
        let ringY = H - sb - Geo.ringLift
        stickRestL = hp(sl + Geo.ringInL, ringY)
        stickRestR = hp(W - sr - Geo.ringInR, ringY)
        stickL.idle(at: stickRestL)
        stickR.idle(at: stickRestR)
        dashButton.node.position = hp(W - sr - Geo.dashIn, H - sb - Geo.dashUp)
        abilityButton.node.position = hp(W - sr - Geo.abilityIn, H - sb - Geo.abilityUp)
        // toasts never stack down into the dash button (the right column) / the move ring (the left one, H1)
        toastFloor = hp(0, H - sb - Geo.dashUp - dashButton.radius - 8).y
        toastFloorL = hp(0, H - sb - Geo.ringLift - Geo.ringR - 8).y

        // hint: in the gap between the stick rings, its bottom line just above the armour block (web #hHint in
        // landscape: anchored at its bottom); a longer one takes two lines growing upward
        let gapL = sl + Geo.ringInL + Geo.ringR, gapR = W - sr - Geo.ringInR - Geo.ringR
        hintGap = (gapL - W / 2, gapR - W / 2)
        hintBase = hp((gapL + gapR) / 2, bottom - Geo.armourH - 24)
        hintUp = true
        hintMaxW = max(160, gapR - gapL - 24)
        fitHint()

        // banner (title clamp(30, 13 % of the height, 52): a landscape phone is short); its slot (H1: middle — 30 % of the
        // height —, or in a hold / a boss fight high or low, `placeBanner`) is applied again below
        let bw = min(560, W * 0.7)
        banner.position = hp(W / 2, H * 0.30 + st)
        bannerTitle.size = max(30, min(52, H * 0.13))
        bannerSub.kern = 3.6
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
        bandBottom = objBottom
        placeBand()
        measureBanner()
        bannerCentreY = bannerSlotY(bannerSlot)
        banner.position = hp(W / 2, bannerCentreY)
    }

    /// Armour block rect (view points, y down), the lowest toast's floor (HUD y).
    private var armourRect = CGRect.zero
    private var toastFloor: CGFloat = -1e6

    /// The coach card's widest: centred, clear of the squad alert column on the left (and so of the mirror band on
    /// the right).
    private var coachMaxWidth: CGFloat {
        let sl = max(16, insets.left)
        return max(240, min(520, size.width - 2 * (sl + Geo.rowW + 10)))
    }

    private var statsTop: CGFloat = 0, statsLeft: CGFloat = 0, statsKillsW: CGFloat = -1, statsComboW: CGFloat = -1
    private var objLayoutStatsRight: CGFloat = -1

    /// Stats panel from the current kill-count and combo widths (web .hud-tl: kills, time, combo in one flex row;
    /// re-built only when a column moves by a 10 pt step).
    private func fitStats() {
        // (a column is as wide as its number or its caption, whichever is wider: longer languages)
        let kw = max(38, (max(killsVal.width, killsCap.width) / 10).rounded(.up) * 10)
        let cwid: CGFloat = comboLast >= 5 ? max(30, (comboVal.width / 10).rounded(.up) * 10) : 0
        if kw == statsKillsW && cwid == statsComboW { return }
        statsKillsW = kw
        statsComboW = cwid
        let statsH: CGFloat = 40
        let timeX = 13 + kw + 13
        let timeW = max(48, timeVal.width, timeCap.width)
        let statsW = max(124, timeX + timeW + (cwid > 0 ? 14 + cwid : 0) + 14)
        statsRect = CGRect(x: statsLeft, y: statsTop, width: statsW, height: statsH)
        statsPanel.removeFromParent()
        statsPanel = Shapes.stretchedPanel(width: statsW, height: statsH, baseWidth: 124)
        statsPanel.position = hp(statsLeft, statsTop)
        statsPanel.zPosition = -1
        root.addChild(statsPanel)
        timeCap.node.position = hp(statsLeft + timeX, statsTop + 12)
        timeVal.node.position = hp(statsLeft + timeX, statsTop + 29)
        comboVal.node.position = hp(statsLeft + timeX + timeW + 14, statsTop + statsH / 2 + 1)
        layoutObjective(statsRight: statsLeft + statsW)
    }

    /// Objective box: centred between the stats panel and the pause button, pushed right / narrowed so it never
    /// overlaps either (web .hud-obj flex item in landscape).
    private func layoutObjective(statsRight: CGFloat) {
        let W = size.width
        let sl = max(16, insets.left), sr = max(16, insets.right)
        let top = 10 + insets.top
        if statsRight == objLayoutStatsRight { return }
        objLayoutStatsRight = statsRight
        var objW = min(480, W - sl - sr - 124 - 44 - 40)
        let objX = max((W - objW) / 2, statsRight + 10)
        objW = max(160, min(objW, W - sr - 44 - 10 - objX))
        let objY = top
        let objH: CGFloat = 46
        objRect = CGRect(x: objX, y: objY, width: objW, height: objH)
        objText.size = W <= 700 ? 14 : 16
        objBar.resize(width: objW - 32)
        objBar.node.position = hp(objX + 16, objY + objH - 5)
        objCap.node.position = hp(objX + objW / 2, objY + 11)
        placeObjText()
        objEdge.size = CGSize(width: 3, height: objH - 7)
        objEdge.position = hp(objX, objY)
        rebuildObjPanel()
        objBottom = objY + objH
        if coachTarget == nil && !coachCard.visible { bandBottom = objBottom }
        placeBand()
    }

    /// The objective text under its caption, scaled down when it is wider than the box.
    private func placeObjText() {
        let r = objRect
        objText.node.position = hp(r.midX, r.minY + 27)
        TextFit.scale(objText, objTextRoom, minScale: HUD.objMinScale)
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

    /// Toasts start under the top band (the objective box, or the coach card while it shows; H1: the hint while a hold
    /// puts it up there) in the right column.
    private func placeBand() {
        let sr = max(16, insets.right), top = 10 + insets.top
        let band = max(bandBottom, hintTopBottom)
        toastRoot.position = hp(size.width - sr, max(top + 52, band + 6))
        // the nameplates never rise above the band either (web plateTop = max(objective, coach card) bottom + 4)
        plates.topLimit = hp(0, band + 4).y
    }

    // ---------------------------------------------------------------- events
    /// A toast's widest (panel; its text 22 pt narrower): 320 pt, less where two columns side by side would touch (SE).
    private var toastMaxWidth: CGFloat { HUD.toastMaxWidth(size.width, insets) }
    static func toastMaxWidth(_ w: CGFloat, _ insets: UIEdgeInsets) -> CGFloat {
        min(320, w * 0.6, ((w - max(16, insets.left) - max(16, insets.right)) / 2 - 4).rounded(.down))
    }

    /// The toast label of `text` for a column (wrapped ones cached: made behind the loading cover) and its frame.
    private func toastLabel(_ text: String, left: Bool) -> (SKLabelNode, CGRect) {
        let maxW = toastMaxWidth
        let key = "\(Int(maxW))|\(left ? "L" : "R")|" + text
        if let c = toastLabels[key], c.0.parent == nil { return c }
        let label = Toast.makeLabel(text, maxWidth: maxW - 22, left: left)
        let lf = label.frame
        // only wrapped ones are kept (single-line labels are cheap to make)
        if toastLabels[key] == nil && lf.height > 20 { toastLabels[key] = (label, lf) }
        return (label, lf)
    }

    /// Panel size of a toast whose label frame is `lf`.
    private func toastSize(_ lf: CGRect) -> CGSize {
        CGSize(width: min(toastMaxWidth, max(80, lf.width + 22)), height: max(26, lf.height + 12))
    }

    /// A toast drawn now in a column (the left one mirrored: its edge against the screen edge, the text left-aligned).
    @discardableResult
    private func makeToast(_ text: String, kind: ToastKind, lane: ToastQueue.Lane, left: Bool, life: Float) -> Toast {
        let (label, lf) = toastLabel(text, left: left)
        let t = Toast(label: label, frame: lf, life: life, lane: lane, left: left)
        let sz = toastSize(lf)
        t.width = sz.width
        t.height = sz.height
        t.panel = SKSpriteNode(color: UIPalette.panel, size: sz)
        t.panel.anchorPoint = CGPoint(x: 0, y: 1)
        t.panel.position = CGPoint(x: left ? 0 : -sz.width, y: 0)
        t.node.addChild(t.panel)
        let edge = SKSpriteNode(color: kind == .warn ? UIPalette.red : (kind == .gold ? UIPalette.amber : UIPalette.teal), size: CGSize(width: 3, height: t.height))
        edge.anchorPoint = CGPoint(x: left ? 0 : 1, y: 1)
        t.node.addChild(edge)
        t.label.position = CGPoint(x: left ? 10 : -10, y: -6)
        t.node.addChild(t.label)
        t.node.alpha = 0
        (left ? toastRootL : toastRoot).addChild(t.node)
        toasts.append(t)
        return t
    }

    /// A toast shown at once in the right column (the loading cover's warm-up; the game's toasts go through `post`).
    func toast(_ text: String, kind: ToastKind, left: Bool = false) {
        makeToast(text, kind: kind, lane: .bark, left: left, life: kind == .warn ? 4.5 : 3.2)
        // (not while warming up: every wrapped toast has to be drawn once behind the cover)
        if toasts.count > 4 && !warming { toasts[0].discard(); toasts.removeFirst() }
    }

    /// A toast of the game (GameScene's event drain): H1 — into the queue, which hands it out when it may show.
    func post(_ text: GameText, kind: ToastKind) { toastQueue.post(text, kind: kind) }

    /// `-holdBanner` (CI shots): the latest banner of the game, kept on screen (the warm-up's banner never is).
    var holdBanner = false
    private var pinnedBanner: (String, String, Bool)? = nil

    /// A banner of the game (GameScene's event drain): shown, and pinned with `-holdBanner`.
    func gameBanner(title: String, subtitle: String, teal: Bool) {
        showBanner(title: title, subtitle: subtitle, teal: teal)
        if holdBanner { pinnedBanner = (title, subtitle, teal) }
    }

    func showBanner(title: String, subtitle: String, teal: Bool) {
        bannerTitle.color = teal ? UIPalette.teal : UIPalette.red
        bannerTitle.set(L10n.upper(title))
        bannerSub.set(L10n.upper(subtitle))
        // a longer title / subtitle than the screen holds scales down (pseudo-localisation, later languages)
        TextFit.scale(bannerTitle, size.width - 32)
        TextFit.scale(bannerSub, size.width - 32)
        bannerBand.color = teal ? UIPalette.bannerTeal : UIPalette.bannerRed
        bannerT = 0
        // H1: its slot is chosen on the next update (the game and the projection are there)
        measureBanner()
        bannerPlace = true
    }

    // ---------------------------------------------------------------- H1: where transient text goes
    /// The banner's slots: middle (30 % of the height, as before), high (its top stripe right under the top band) and low
    /// (its bottom stripe right above the hint's top line, or above the armour block when no hint shows). Outside a hold
    /// and a boss fight a banner keeps the middle; in them it takes the slot that covers least of what matters (`cover`).
    enum BannerSlot: String { case mid, high, low }
    private(set) var bannerSlot = BannerSlot.mid
    private var bannerPlace = false
    /// The placed banner's centre (view y).
    private var bannerCentreY: CGFloat = 0

    /// The banner's reach above / below its centre (the stripes included) and its width (the stripes', or its text's when
    /// wider: set with the text and the layout).
    private var bannerExtent: (up: CGFloat, down: CGFloat, width: CGFloat) {
        let ts = bannerTitle.size
        return (ts * 0.5 + 14 + 3, ts * 0.5 + 30 + 3, bannerWidth)
    }
    private var bannerWidth: CGFloat = 560
    private func measureBanner() { bannerWidth = max(min(560, size.width * 0.7), bannerTitle.width, bannerSub.width) }

    /// The centre (view y) of a slot.
    private func bannerSlotY(_ s: BannerSlot) -> CGFloat {
        let mid = size.height * 0.30 + insets.top
        let e = bannerExtent
        switch s {
        case .mid: return mid
        case .high: return min(mid, max(bandBottom, hintTopBottom) + 6 + e.up)
        case .low:
            // (above an urgent hint; a calm one steps aside while the banner is up — `hintAside`)
            let floor = ((hintUrgent ? hintTopY : nil) ?? (armourRect.minY - 2)) - 6
            return max(mid, floor - e.down)
        }
    }

    /// The banner's rect (view points) in a slot.
    private func bannerRect(_ s: BannerSlot) -> CGRect {
        let e = bannerExtent, y = bannerSlotY(s)
        return CGRect(x: (size.width - e.width) / 2, y: y - e.up, width: e.width, height: e.up + e.down)
    }

    /// The banner's rect (view points) while it is up, else nil.
    private var bannerUpRect: CGRect? {
        let up = pinnedBanner != nil ? !warming : bannerT < (reducedMotion ? 3.4 : 2.4)
        guard up else { return nil }
        let e = bannerExtent
        return CGRect(x: (size.width - e.width) / 2, y: bannerCentreY - e.up, width: e.width, height: e.up + e.down)
    }

    /// The top of the hint's first line (view y) while a hint shows at the bottom, else nil.
    private var hintTopY: CGFloat? {
        if hintText.isEmpty || hintAtTop { return nil }
        let y = (hint2.text.isEmpty ? hint.node.position.y : max(hint.node.position.y, hint2.node.position.y)) + 9 * hint.node.yScale
        return size.height / 2 - y
    }

    /// What must stay visible this frame (view points): the marines (feet to head), the boss, the lift deck while the
    /// squad holds it (the projected rim's ellipse), the objective marker as drawn last frame (before it kept clear of
    /// the toasts) — built only when something is being placed.
    private struct Keep {
        var marines: [CGRect] = []
        var boss: CGRect? = nil
        /// The deck's ellipse: centre and radii (view points).
        var deck: (c: CGPoint, rx: CGFloat, ry: CGFloat)? = nil
        var marker: CGRect? = nil
        var markerOver = false
    }

    /// `gameView` (B3): the game camera's view instead of this frame's — a banner placed while a scripted shot is on (the
    /// boss's, at its arrival in the intro) outlives the shot, so it keeps what the play underneath must show.
    private func keep(_ game: Game, _ projection: HUDProjection, gameView: Bool = false) -> Keep {
        var k = Keep()
        func v(_ x: Float, _ y: Float, _ z: Float) -> CGPoint {
            viewPoint(gameView ? projection.gameHudPoint(x, y, z) : projection.hudPoint(x, y, z))
        }
        for i in 0..<min(4, game.marines.count) {
            let f = projection.feet(i)
            let a = v(f.0, f.1, f.2), b = v(f.0, f.1 + 1.9, f.2)
            k.marines.append(CGRect(x: min(a.x, b.x) - 14, y: min(a.y, b.y) - 6, width: abs(a.x - b.x) + 28, height: abs(a.y - b.y) + 10))
        }
        if game.boss.alive {
            let p = game.boss.position, h = game.boss.height, gy = game.level.groundY(p.x, p.y)
            let y0 = max(gy, h), pts = [v(p.x - 2.5, y0, p.y), v(p.x + 2.5, y0, p.y), v(p.x, y0 + 4, p.y), v(p.x, y0, p.y - 2.5), v(p.x, y0, p.y + 2.5)]
            let xs = pts.map { $0.x }, ys = pts.map { $0.y }
            k.boss = CGRect(x: xs.min()! - 10, y: ys.min()! - 10, width: xs.max()! - xs.min()! + 20, height: ys.max()! - ys.min()! + 20)
        }
        if game.stage == .hold {
            let L = game.level.layout.lift
            let c = v(L.x, L.y, L.z)
            let e = v(L.x + L.r, L.y, L.z), w = v(L.x - L.r, L.y, L.z), n = v(L.x, L.y, L.z - L.r), s = v(L.x, L.y, L.z + L.r)
            k.deck = (c, max(abs(e.x - w.x), abs(n.x - s.x)) / 2, max(abs(n.y - s.y), abs(e.y - w.y)) / 2)
        }
        k.marker = marker.isHidden ? nil : markerBox
        k.markerOver = markerOverTarget
        return k
    }

    /// Fraction (0…1) of the deck's ellipse a rect covers (a 12 × 6 sample of the rect).
    private static func deckCover(_ r: CGRect, _ d: (c: CGPoint, rx: CGFloat, ry: CGFloat)) -> CGFloat {
        guard d.rx > 1, d.ry > 1 else { return 0 }
        var n = 0
        for i in 0..<12 {
            for j in 0..<6 {
                let x = (r.minX + (CGFloat(i) + 0.5) / 12 * r.width - d.c.x) / d.rx
                let y = (r.minY + (CGFloat(j) + 0.5) / 6 * r.height - d.c.y) / d.ry
                if x * x + y * y < 1 { n += 1 }
            }
        }
        return CGFloat(n) / 72 * (r.width * r.height) / (.pi * d.rx * d.ry)
    }

    /// What a rect would hide: marines (30 each), the boss (60), the toast's own thing (100), the objective marker (40
    /// over its target, 12 at the edge), the deck (20 × the fraction covered). (counts for the log)
    private func cover(_ r: CGRect, _ k: Keep, thing: CGRect? = nil, deckK: CGFloat = 20) -> (cost: CGFloat, squad: Int, boss: Bool, deck: CGFloat, thing: Bool, marker: Bool) {
        var c: CGFloat = 0
        let squad = k.marines.filter { $0.intersects(r) }.count
        c += CGFloat(squad) * 30
        let boss = k.boss?.intersects(r) ?? false
        if boss { c += 60 }
        let th = thing?.intersects(r) ?? false
        if th { c += 100 }
        let mk = k.marker?.intersects(r) ?? false
        if mk { c += k.markerOver ? 40 : 12 }
        let dk = k.deck.map { HUD.deckCover(r, $0) } ?? 0
        c += deckK * dk
        return (c, squad, boss, dk, th, mk)
    }

    private func pct(_ x: CGFloat) -> String { "\(Int((x * 100).rounded()))%" }

    /// A new banner's slot: the middle outside a hold / a boss fight; in them the cheapest of middle, high and low.
    private func placeBanner(_ game: Game, _ projection: HUDProjection) {
        var best = BannerSlot.mid
        var why = ""
        if game.stage == .hold || game.boss.alive {
            let k = keep(game, projection, gameView: shotOn)
            // (a hint up under the top band is never covered: the high slot is under it, the middle one may not be)
            let hintTop: CGRect? = hintAtTop && !hintText.isEmpty ? hintRects().top : nil
            var bestC = CGFloat.infinity
            for (s, pref) in [(BannerSlot.mid, CGFloat(0)), (.high, 1), (.low, 2)] {
                let r = bannerRect(s)
                if let h = hintTop, h.intersects(r) { why += " \(s.rawValue): over the hint"; continue }
                let c = cover(r, k)
                why += " \(s.rawValue): squad \(c.squad) boss \(c.boss ? 1 : 0) deck \(pct(c.deck))"
                if c.cost + pref < bestC { bestC = c.cost + pref; best = s }
            }
        }
        bannerSlot = best
        bannerCentreY = bannerSlotY(best)
        banner.position = hp(size.width / 2, bannerCentreY)
        if AppLog.diagnostics {
            AppLog.info("hud banner «\(bannerTitle.text)» slot=\(best.rawValue)" + (why.isEmpty ? " (no hold)" : " |" + why)
                        + (shotOn && !why.isEmpty ? " (for the game camera's view: a scripted shot is on)" : ""))
        }
    }

    /// B3: a scripted shot is on this frame (GameScene: Cinematics' close-shot weight) — `placeBanner` judges by the game
    /// camera's view then.
    var shotOn = false

    /// H1: the hint's place in a hold — at the bottom (its home) or, when that would hide more of the squad, the boss or
    /// the deck, right under the top band (the toasts and the plates go under it then).
    private var hintAtTop = false
    private var hintPlace = false
    /// The bottom (view y) of the hint at the top (0: it is at the bottom).
    private var hintTopBottom: CGFloat = 0

    /// The hint's two candidate rects (view points): bottom and top.
    private func hintRects() -> (bottom: CGRect, top: CGRect) {
        let w = hintWidest * hint.node.xScale + 8, lines: CGFloat = hint2.text.isEmpty ? 1 : 2
        let h = lines * 17 * hint.node.yScale + 4
        let b = viewPoint(hintBottomBase)
        let bottom = CGRect(x: b.x - w / 2, y: b.y + 9 * hint.node.yScale - h, width: w, height: h)
        let top = CGRect(x: (size.width - w) / 2, y: bandBottom + 6, width: w, height: h)
        return (bottom, top)
    }

    private func placeHint(_ game: Game, _ projection: HUDProjection) {
        hintPlace = false
        var top = false
        var why = ""
        if game.stage == .hold && !hintText.isEmpty {
            let k = keep(game, projection)
            let r = hintRects()
            let cb = cover(r.bottom, k), ct = cover(r.top, k)
            // (never under a banner that is up there)
            top = ct.cost + 2 < cb.cost && !(bannerUpRect?.intersects(r.top) ?? false)
            why = " | bottom: squad \(cb.squad) boss \(cb.boss ? 1 : 0) deck \(pct(cb.deck)) · top: squad \(ct.squad) boss \(ct.boss ? 1 : 0) deck \(pct(ct.deck))"
        }
        let was = hintAtTop
        hintAtTop = top
        // (back at the bottom: the lines are fitted there again)
        if was && !top { fitHint(); hintPlace = false }
        applyHintPlace()
        if AppLog.diagnostics && !why.isEmpty {
            AppLog.info("hud hint «\(hintText.prefix(32))» at \(top ? "top" : "bottom")" + why)
        }
    }

    /// Moves the fitted hint lines to the top slot or back (fitHint placed them at the bottom).
    private func applyHintPlace() {
        if hintAtTop && !hintText.isEmpty {
            let lh = 17 * hint.node.yScale
            let y0 = hp(0, bandBottom + 6 + 9 * hint.node.yScale).y
            hint.node.position = CGPoint(x: 0, y: y0)
            hint2.node.position = CGPoint(x: 0, y: y0 - lh)
            hintTopBottom = bandBottom + 6 + (hint2.text.isEmpty ? 1 : 2) * lh + 2
        } else {
            hintTopBottom = 0
        }
        placeBand()
    }

    // ---------------------------------------------------------------- H1: the toast columns
    /// The top of a column (view y).
    private func toastTop(left: Bool) -> CGFloat { left ? toastTopL : size.height / 2 - toastRoot.position.y }

    /// Where a new toast of `sz` would go in a column (view points): under the toasts it shows now.
    private func nextToastRect(left: Bool, size sz: CGSize) -> CGRect {
        var y = toastTop(left: left)
        for t in toasts where t.left == left && t.going < 0 { y += t.height + 4 }
        let x = left ? max(16, insets.left) : size.width - max(16, insets.right) - sz.width
        return CGRect(x: x, y: y, width: sz.width, height: sz.height)
    }

    /// The rect (view points) a column's toasts take now, nil when empty.
    private func columnRect(left: Bool) -> CGRect? {
        var r: CGRect? = nil
        for t in toasts where t.left == left {
            let p = viewPoint((left ? toastRootL : toastRoot).position)
            let y = p.y - t.node.position.y
            let tr = CGRect(x: left ? p.x : p.x - t.width, y: y, width: t.width, height: t.height)
            r = r.map { $0.union(tr) } ?? tr
        }
        return r
    }

    /// The toasts on screen (HUD coordinates, y up), the ones at least `minAlpha` visible.
    private func toastRects(minAlpha: CGFloat = 0.05) -> [CGRect] {
        if covered || !visible { return [] }
        var out: [CGRect] = []
        for t in toasts where t.node.alpha >= minAlpha {
            let o = (t.left ? toastRootL : toastRoot).position
            let top = o.y + t.node.position.y
            out.append(CGRect(x: t.left ? o.x : o.x - t.width, y: top - t.height, width: t.width, height: t.height))
        }
        return out
    }

    /// The column a new toast takes: the one where it hides least — its own thing first (the duct mouth, the perched
    /// spitter, the Dropper, the valve …), then the objective marker, the squad, the boss and the deck (`cover`); on a tie
    /// the side away from where the marker points (the way the squad is heading: in the first minute the top right, over
    /// the bridge and its overhead), the right one with no marker; the column already showing toasts when it is close (a
    /// stack stays together); never one that has no room left above its floor.
    private func toastSide(_ sz: CGSize, thing: ToastThing, game: Game, projection: HUDProjection) -> (left: Bool, why: String) {
        let k = keep(game, projection)
        var box: CGRect? = nil
        if case .at(let p) = thing {
            let a = viewPoint(projection.hudPoint(p.x, p.y, p.z))
            box = CGRect(x: a.x - 24, y: a.y - 30, width: 48, height: 44)
        }
        // (the marker's side: 3 for the column on the side it points to, else 1 for the left one)
        let mx = k.marker.map { $0.midX - size.width / 2 }
        func ahead(_ left: Bool) -> CGFloat {
            guard let x = mx, abs(x) > 40 else { return left ? 1 : 0 }
            return (x < 0) == left ? 3 : 0
        }
        var best = (left: false, cost: CGFloat.infinity)
        var why = ""
        for left in [false, true] {
            let r = nextToastRect(left: left, size: sz)
            let c = cover(r, k, thing: box, deckK: 10)
            var cost = c.cost + ahead(left)
            if toasts.contains(where: { $0.left == left && $0.going < 0 }) { cost -= 2 }
            let floor = size.height / 2 - (left ? toastFloorL : toastFloor)
            if r.maxY > floor { cost += 200 }
            why += " | \(left ? "left" : "right"): thing \(c.thing ? 1 : 0) marker \(c.marker ? 1 : 0) squad \(c.squad) boss \(c.boss ? 1 : 0) deck \(pct(c.deck))"
            if cost < best.cost { best = (left, cost) }
        }
        if box == nil { why = " (names nothing on screen)" + why }
        return (best.left, why)
    }

    /// One toast the queue handed out: a newer bark replaces the one on screen; the side; drawn.
    private func showQueued(_ s: ToastQueue.Show, game: Game, projection: HUDProjection) {
        let text = L10n.string(s.text)
        if s.lane == .bark { for t in toasts where t.lane == .bark && t.going < 0 { t.going = HUD.toastQuickFade } }
        let sz = toastSize(toastLabel(text, left: false).1)
        let side = toastSide(sz, thing: ToastThing.of(s.text, game), game: game, projection: projection)
        makeToast(text, kind: s.kind, lane: s.lane, left: side.left, life: s.life)
        if AppLog.diagnostics {
            AppLog.info(String(format: "hud toast %@ %@ %@ t=%.1f waited %.1f s", ToastQueue.name(s.lane), s.text.id.rawValue,
                               side.left ? "left" : "right", game.time, s.waited) + side.why)
        }
    }

    /// A replaced toast fades out this fast (s).
    private static let toastQuickFade: Float = 0.2

    /// The queue, then both columns: the left one under the stats and the squad rows shown; a column a banner covers
    /// steps aside (fades out in 0.15 s, its clocks stop) until the banner has gone; toasts age only while seen.
    private func updateToasts(game: Game, dt: Float, projection: HUDProjection) {
        let sl = max(16, insets.left), top = 10 + insets.top
        var rows = 0
        for r in squad where !r.node.isHidden { rows += 1 }
        toastTopL = max(top + 48 + CGFloat(rows) * Geo.rowStep + (rows > 0 ? 2 : 0), max(bandBottom, hintTopBottom) + 6)
        toastRootL.position = hp(sl, toastTopL)
        let br = warming ? nil : bannerUpRect
        let step = CGFloat(dt / 0.15)
        let asideR = br.map { b in columnRect(left: false).map { $0.intersects(b) } ?? false } ?? false
        let asideL = br.map { b in columnRect(left: true).map { $0.intersects(b) } ?? false } ?? false
        toastColA.r = asideR ? max(0, toastColA.r - step) : min(1, toastColA.r + step)
        toastColA.l = asideL ? max(0, toastColA.l - step) : min(1, toastColA.l + step)
        // what may start now (nothing under a banner, a menu or the cover's warm-up)
        if !warming {
            var st = ToastQueue.State(hold: covered || br != nil)
            st.tipShown = toasts.contains { $0.lane == .tip && $0.going < 0 }
            if let b = toasts.last(where: { $0.lane == .bark && $0.going < 0 }) { st.barkShownFor = b.t }
            if let h = game.contextHint { st.threatHint = h.text.id == .hintPinned || h.text.id == .hintPlayerDown }
            for s in toastQueue.update(dt: dt, state: st, fresh: { t, _ in ToastThing.of(t, game).fresh }) {
                showQueued(s, game: game, projection: projection)
            }
        }
        for left in [false, true] {
            let colA = left ? toastColA.l : toastColA.r
            let running = warming || (!covered && colA >= 1)
            // a column that would reach its floor lets one go: its oldest bark, else its oldest threat, else its oldest
            var stackH: CGFloat = -4
            for t in toasts where t.left == left && t.going < 0 { stackH += t.height + 4 }
            let rootY = (left ? toastRootL : toastRoot).position.y
            let floor = left ? toastFloorL : toastFloor
            if !warming && rootY - stackH < floor {
                let live = toasts.filter { $0.left == left && $0.going < 0 }
                if live.count > 1, let v = live.first(where: { $0.lane == .bark }) ?? live.first(where: { $0.lane == .threat }) ?? live.first {
                    v.going = HUD.toastQuickFade
                }
            }
            var y: CGFloat = 0
            for t in toasts where t.left == left {
                if running {
                    t.t += dt
                    // (a quick fade-out runs down to exactly 0: then it goes)
                    if t.going > 0 { t.going = max(0, t.going - dt) }
                }
                let u = min(1, t.t / t.life)
                var a = CGFloat(u < 0.08 ? u / 0.08 : (u > 0.85 ? (1 - u) / 0.15 : 1))
                if t.going >= 0 { a *= CGFloat(t.going / HUD.toastQuickFade) }
                t.node.alpha = a * colA
                let slide = u < 0.08 ? CGFloat((1 - u / 0.08) * 20) : 0
                t.node.position = CGPoint(x: left ? -slide : slide, y: y)
                y -= t.height + 4
            }
        }
        var k = 0
        while k < toasts.count {
            let t = toasts[k]
            if t.t >= t.life || t.going == 0 {
                t.discard()
                toasts.remove(at: k)
                continue
            }
            k += 1
        }
    }

    /// Loading-cover warm-up: every overlay, a banner, a toast and both cooldown pies on screen for a few frames
    /// (first use of each would otherwise build its pipeline / textures mid-game), then back to normal.
    private var warming = false
    /// Texts of the glyph labels that start empty (combo, marker distance), kept while the warm-up shows every glyph.
    private var warmTexts = ("", "")
    /// v1.1 warm-up: the objective box's new text styles, its panel / edge / bar variants, the coach card, the ghost
    /// thumb, the target rings and the urgent marker, drawn once behind the cover.
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
        // one label per new font / size / colour of the objective box (every text texture is new anyway: what is warmed
        // is the style; few labels, so the warm-up creates and frees as few text textures as possible)
        let objStyles: [(String, CGFloat, SKColor)] = [
            (L10n.string(GameText(.objWakingBeacon)), objText.size, UIPalette.amber), (L10n.string(GameText(.objConvergeBeacon)), objText.size, UIPalette.red)]
        for (t, sz, c) in objStyles {
            let l = Label(L10n.upper(t), font: Fonts.semibold, size: sz, color: c, kern: 0.6)
            l.node.position = CGPoint(x: 0, y: y)
            n.addChild(l.node)
            y -= 18
        }
        // (B3: the boss style's caption is the boss's name)
        for (text, cap) in [(L10n.ui(.hudObjective), UIPalette.red), (L10n.name(BossKind.queen.name), UIPalette.queen)] {
            let l = Label(L10n.upper(text), font: Fonts.medium, size: 12, color: cap, kern: 2.4)
            l.node.position = CGPoint(x: -W / 4, y: y); n.addChild(l.node); y -= 16
        }
        for (fill, edge) in [(UIPalette.panel, UIPalette.amber), (UIPalette.redPanel, UIPalette.red), (UIPalette.panel, UIPalette.queen)] {
            for h in [46] as [CGFloat] {
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
        // the hint line's style (hold hints, revive lines) is the existing amber / red hint label's
        root.addChild(n)
        warmNode = n
        // the card with a two-line text, the thumb, the rings, the red marker
        coachCard.show(step: 1, text: L10n.upper(L10n.string(CoachText.text(step: 1, cls: .assault, keyboard: false))), centerX: 0,
                       top: hp(0, objBottom + 2).y, maxWidth: coachMaxWidth)
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
            comboVal.set(HUD.comboCharset)
            markerLabel.set(HUD.markerCharset)
            lvl.set(HUD.levelCharset)
            screenFlash(0.6); damageFlash(0.8); hordeFlash()
            showBanner(title: L10n.string(.hordeTitle), subtitle: L10n.string(.hordeSubtitle), teal: false)
            toast(L10n.string(GameText(.toastUpgrade, [.name(.upgrade(.dmg))])), kind: .info)
            // every wrapped toast of a mission (the catalog's: bug tips, the squad's down / up lines, the medkit), so its
            // label exists before the mission needs it (single-line ones are cheap and not kept) — in both columns (H1)
            for t in TextWarmup.toastTexts() { toast(L10n.string(t), kind: .warn) }
            for t in TextWarmup.toastTexts() { toast(L10n.string(t), kind: .warn, left: true) }
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
            bannerPlace = false
            toastColA = (1, 1)
            for t in toasts { t.discard() }
            toasts.removeAll()
            comboVal.set(warmTexts.0)
            markerLabel.set(warmTexts.1)
            levelShown = -1
            abilityButton.update(ready: true, fraction: 0)
            dashButton.update(ready: true, fraction: 0)
            abilityButton.warmPies(false)
            dashButton.warmPies(false)
        }
    }

    /// `-layoutCheck` (LAND): every fixed HUD element and its reserved room — stats, objective, pause, the squad alert
    /// column, the widest coach card with «Пропустить», the toast column under it down to the dash button, the
    /// two-line hint, the armour block, both stick rings and captions, the dash and ability buttons — then overlaps,
    /// elements outside the safe area and taps under 44 pt (LayoutCheck). `tag` names the case in the log line.
    func checkLayout(tag: String = "hud") {
        let W = size.width, H = size.height
        var check = LayoutCheck(tag)
        func hud(_ r: CGRect) -> CGRect { CGRect(x: r.minX - W / 2, y: H / 2 - r.maxY, width: r.width, height: r.height) }
        let sl = max(16, insets.left), sr = max(16, insets.right), top = 10 + insets.top
        check.add("stats", hud(statsRect))
        check.add("objective", hud(objRect))
        check.add("pause", hud(CGRect(x: W - sr - 44, y: top, width: 44, height: 44)))
        check.tap("pause", hud(pauseRect))
        check.add("squad", hud(CGRect(x: sl, y: top + 48, width: Geo.rowW, height: 3 * Geo.rowStep - 4)))
        // the widest coach card under the objective, «Пропустить» at its right end
        let cw = coachMaxWidth, cardTop = objBottom + 2
        check.add("coach", hud(CGRect(x: (W - cw) / 2, y: cardTop, width: cw, height: 44)))
        check.tap("coach.skip", MenuButton.tapRect(CGRect(x: cw / 2 - 4 - 60, y: hp(0, cardTop + 44).y, width: 60, height: 44), pad: 0))
        // toasts: the right column under the card, down to the dash button (room for at least one two-line toast)
        let toastW = toastMaxWidth, toastTop = max(top + 52, cardTop + 44 + 6)
        let toastBottom = H / 2 - toastFloor
        check.add("toasts", hud(CGRect(x: W - sr - toastW, y: toastTop, width: toastW, height: max(1, toastBottom - toastTop))))
        if toastBottom - toastTop < 40 { check.add("toasts.room<40", CGRect(x: -W, y: -H, width: 1, height: 1)) }
        // H1: the left column under all three squad rows (and the card), down to the move ring: room for at least a one-line
        // toast (a toast takes it only where it fits — HUD.toastSide; the right column is the one sure of a two-line toast)
        let leftTop = max(top + 48 + 3 * Geo.rowStep + 2, cardTop + 44 + 6), leftBottom = H / 2 - toastFloorL
        check.add("toasts.left", hud(CGRect(x: sl, y: leftTop, width: toastW, height: max(1, leftBottom - leftTop))))
        if leftBottom - leftTop < 26 { check.add("toasts.left.room<26", CGRect(x: -W, y: -H, width: 1, height: 1)) }
        // the hint at its widest, two lines
        let hb = viewPoint(hintBase)
        check.add("hint", hud(CGRect(x: hb.x - hintMaxW / 2, y: hb.y - 17 - 9, width: hintMaxW, height: 35)))
        if hb.y + 9 > armourRect.minY - 8 { check.add("hint.clearance<8", CGRect(x: -W, y: -H, width: 1, height: 1)) }
        check.add("armour", hud(armourRect))
        for (name, st, rest) in [("move", stickL, stickRestL), ("aim", stickR, stickRestR)] {
            let c = viewPoint(rest), R = Geo.ringR
            check.add("ring." + name, hud(CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)))
            let cap = st.captionSize
            check.add("caption." + name, hud(CGRect(x: c.x - cap.width / 2, y: c.y + R + 14 - cap.height / 2, width: cap.width, height: cap.height)))
        }
        for (name, b) in [("dash", dashButton), ("ability", abilityButton)] {
            let c = b.node.position, r = b.radius
            check.add(name, CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            check.tap(name, CGRect(x: c.x - r - 10, y: c.y - r - 10, width: 2 * r + 20, height: 2 * r + 20))
        }
        checkTexts(&check)
        check.report(size: size, insets: insets)
        checkSlots()
    }

    /// H1 `-layoutCheck` («hud-slots»): the places transient text may take in a hold — the banner's three slots (middle;
    /// high, right under the top band; low, right above a two-line hint) and the hint's top place — each clear of the
    /// top band, the armour block and the hint at the bottom (the slots are alternatives: they may overlap each other).
    func checkSlots() {
        let W = size.width, H = size.height
        var check = LayoutCheck("hud-slots")
        func hud(_ r: CGRect) -> CGRect { CGRect(x: r.minX - W / 2, y: H / 2 - r.maxY, width: r.width, height: r.height) }
        let sr = max(16, insets.right), top = 10 + insets.top
        check.add("stats", hud(statsRect))
        check.add("objective", hud(objRect))
        check.add("pause", hud(CGRect(x: W - sr - 44, y: top, width: 44, height: 44)))
        check.add("armour", hud(armourRect))
        let hb = viewPoint(hintBase)
        let hintR = CGRect(x: hb.x - hintMaxW / 2, y: hb.y - 17 - 9, width: hintMaxW, height: 35)
        check.add("hint", hud(hintR))
        let e = bannerExtent, bw = min(560, W * 0.7)
        let mid = H * 0.30 + insets.top
        let slots: [(String, CGFloat)] = [("mid", mid), ("high", min(mid, objBottom + 6 + e.up)), ("low", max(mid, hintR.minY - 6 - e.down))]
        for (n, y) in slots {
            check.add("slot#banner." + n, hud(CGRect(x: (W - bw) / 2, y: y - e.up, width: bw, height: e.up + e.down)))
        }
        check.add("slot#hint.top", hud(CGRect(x: (W - hintMaxW) / 2, y: objBottom + 6, width: hintMaxW, height: 35)))
        check.report(size: size, insets: insets)
    }

    /// L10n: every text the HUD can show, at its widest arguments, against its container after the fitting the HUD
    /// applies — objective lines, coach card lines (every step, touch and keyboard, every class's ability), hints
    /// (split in two, then scaled), banners, squad names, round-button labels.
    private func checkTexts(_ check: inout LayoutCheck) {
        func w(_ s: String, _ font: String, _ size: CGFloat, _ kern: CGFloat) -> CGFloat { TextFit.width(s, font: font, size: size, kern: kern) }
        for t in HUD.objectiveSamples {
            check.text("text.objective." + t.id.rawValue, width: w(L10n.upper(L10n.string(t)), Fonts.semibold, objText.size, 0.6),
                       room: objTextRoom, minScale: HUD.objMinScale)
        }
        // B3: the box's caption — «OBJECTIVE», and in the boss style every boss's name (the boss bar)
        check.text("text.objective.caption", width: w(L10n.upper(L10n.ui(.hudObjective)), Fonts.medium, 12, 2.4), room: objTextRoom,
                   minScale: HUD.objMinScale)
        for k in BossKind.allCases {
            check.text("text.objective.boss." + k.rawValue, width: w(L10n.upper(L10n.name(k.name)), Fonts.medium, 12, 2.4),
                       room: objTextRoom, minScale: HUD.objMinScale)
        }
        let cw = coachMaxWidth
        for step in 0..<CoachText.steps {
            for kb in [false, true] {
                for c in MarineClass.allCases where step == 2 || c == .assault {
                    let s = L10n.upper(L10n.string(CoachText.text(step: step, cls: c, keyboard: kb)))
                    let L = CoachCard.lines(s, maxWidth: cw, counterW: coachCard.counterWidth, skipW: coachCard.skipWidth)
                    check.text("text.coach.\(step)\(kb ? "k" : "")." + c.id, width: L.widest, room: L.avail, minScale: CoachCard.lineMinScale)
                }
            }
        }
        for (k, t) in HUD.hintSamples.enumerated() {
            let s = L10n.upper(t)
            var widest = HUD.hintWidth(s)
            if widest > hintMaxW {
                let (a, b) = HUD.splitHint(s)
                widest = b.isEmpty ? widest : max(HUD.hintWidth(a), HUD.hintWidth(b))
            }
            check.text("text.hint.\(k)", width: widest, room: hintMaxW, minScale: 0.6)
        }
        for (t, s) in HUD.bannerSamples {
            check.text("text.banner." + t.id.rawValue, width: w(L10n.upper(L10n.string(t)), Fonts.bold, bannerTitle.size, 4), room: size.width - 32, minScale: 0.5)
            check.text("text.banner." + s.id.rawValue, width: w(L10n.upper(L10n.string(s)), Fonts.medium, 12, 3.6), room: size.width - 32, minScale: 0.5)
        }
        for n in [NameRef.player] + MarineClass.allCases.map({ NameRef.callsign($0) }) {
            check.text("text.squad." + n.key, width: w(L10n.upper(L10n.name(n)), Fonts.medium, 12, 1.0), room: HUD.squadNameRoom, minScale: 0.5)
        }
        for c in MarineClass.allCases {
            check.text("text.ability." + c.id, width: w(L10n.upper(L10n.name(.abilityShort(c))), Fonts.semibold, 12, 0.5),
                       room: abilityButton.labelRoom(abilityButton.radius), minScale: 0.5)
        }
        check.text("text.dash", width: w(L10n.upper(L10n.ui(.hudDash)), Fonts.semibold, 12, 0.5), room: dashButton.labelRoom(dashButton.radius), minScale: 0.5)
    }

    /// Every objective line at its widest arguments.
    static var objectiveSamples: [GameText] {
        var out: [GameText] = (0..<3).map { GameText(.objHoldBeacon, [.name(.beacon($0))]) }
        out.append(GameText(.objLightBeacons, [.int(3), .int(3)]))
        out.append(GameText(.objHoldLift, [.clock(100)]))
        for id in [TextID.objConvergeBeacon, .objWakingBeacon, .objConvergeLift, .objWakingLift, .objLiftCalled, .objLiftLocked, .objKillQueen, .objExtract] {
            out.append(GameText(id))
        }
        // the mission modules' own lines (switches, a hold on a deck, a boss step, on the way: R1)
        out += Game.moduleObjectiveSamples
        return out
    }

    /// Every hint line (core hints, the three tiers' hold hints, the revive lines, the app's control hint), resolved.
    static var hintSamples: [String] {
        var out = [TextID.hintPlayerDown, .hintReviveNear, .hintBackToRing, .hintRingContested, .hintStepInRing, .hintToPlatform,
                   .hintBackToSwitch, .hintBackToGenerator].map { L10n.string(GameText($0)) }
        out += Difficulty.tiers.map { L10n.string(Game.holdHintText($0)) }
        out += CoachText.reviveLines.map { L10n.string($0) }
        out.append(L10n.ui(.hudControlHint))
        return out
    }

    /// Every banner the core raises (title, subtitle) at its widest arguments.
    static var bannerSamples: [(GameText, GameText)] {
        [(GameText(.bannerDrop), GameText(.bannerDropSub, [.name(.sector(letter: 11, number: 88))])),
         (.hordeTitle, .hordeSubtitle),
         (GameText(.bannerDefend), GameText(.bannerDefendSub, [.name(.beacon(2))])),
         (.hordeTitle, GameText(.bannerHordeLiftSub)),
         (GameText(.bannerLiftCalled), GameText(.bannerLiftCalledSub)),
         (GameText(.bannerBeaconOnline), GameText(.bannerBeaconOnlineSub, [.int(2), .int(3)])),
         (GameText(.bannerHold), GameText(.bannerHoldSub, [.int(100)])),
         (GameText(.bannerExtract), GameText(.bannerExtractSub)),
         (GameText(.bannerQueen), GameText(.bannerQueenSub)),
         (GameText(.bannerQueenRage), .hordeSubtitle),
         (GameText(.bannerQueenDead), GameText(.bannerQueenDeadSub)),
         // Stage 1 R7: Breaker Run's and Vent Purge's drop banners, the breakers live, the generator hold
         (GameText(.bannerBreakerRun), GameText(.bannerBreakerRunSub, [.name(.sector(letter: 11, number: 88))])),
         (GameText(.bannerBreakersLive), GameText(.bannerBreakersLiveSub)),
         (GameText(.bannerGenerator), GameText(.bannerGeneratorSub, [.int(60)])),
         (GameText(.bannerVentPurge), GameText(.bannerVentPurgeSub, [.name(.sector(letter: 11, number: 88))])),
         // Stage 2 B4: the Manifold's drop banner, the Threader's arrival and its death (H1: in the text-fit checks)
         (GameText(.bannerManifold), GameText(.bannerManifoldSub, [.name(.sector(letter: 11, number: 88))])),
         (GameText(.bannerThreader), GameText(.bannerThreaderSub)),
         (GameText(.bannerThreaderDead), GameText(.bannerThreaderDeadSub))]
    }

    // (native-vx-feel: a calmer screen — the red vignette of a bite, the white flash of a blast and the red edge of a horde
    // are kept, at about half their strength; the horde's edge no longer strobes)
    func damageFlash(_ a: Float) { damageA = min(1, damageA + a * 0.6) }
    func screenFlash(_ a: Float) { flashA = max(flashA, a * 0.5) }
    func hordeFlash() { hordeA = 0.38 }

    /// HUD point inside the pause button?
    func pauseHit(viewPoint p: CGPoint) -> Bool { pauseRect.contains(p) }

    /// HUD point on the coach card's «Пропустить»?
    func coachSkipHit(_ p: CGPoint) -> Bool { !root.isHidden && coachCard.contains(p) }

    /// The hint in one line, or in two when it is wider than `hintMaxW` (split at « · » / « — », else the middle
    /// space); a line that is still too wide (667 pt landscape) scales both down. Runs on a text change or a layout.
    private func fitHint() {
        let t = hintText
        var l1 = t, l2 = ""
        var widest = t.isEmpty ? 0 : HUD.hintWidth(t)
        if widest > hintMaxW {
            (l1, l2) = HUD.splitHint(t)
            widest = l2.isEmpty ? widest : max(HUD.hintWidth(l1), HUD.hintWidth(l2))
        }
        hint.set(l1)
        hint2.set(l2)
        let s = widest > hintMaxW ? max(0.6, hintMaxW / widest) : 1
        hint.node.setScale(s)
        hint2.node.setScale(s)
        if AppLog.diagnostics && !l2.isEmpty {
            AppLog.info(String(format: "hint 2 lines widest=%.0f max=%.0f scale=%.2f", widest, hintMaxW, s) + " «\(l1)» / «\(l2)»")
        }
        let lh = 17 * s
        let half = widest * s / 2
        let lo = hintGap.0 + 12 + half, hi = hintGap.1 - 12 - half
        let base = CGPoint(x: lo <= hi ? max(lo, min(hi, 0)) : hintBase.x, y: hintBase.y)
        // H1: its bottom place and width; the next update decides where it goes (in a hold it may go under the top band)
        hintWidest = widest
        hintBottomBase = base
        hintPlace = true
        if l2.isEmpty {
            hint.node.position = base
        } else if hintUp {
            hint.node.position = CGPoint(x: base.x, y: base.y + lh)
            hint2.node.position = base
        } else {
            hint.node.position = base
            hint2.node.position = CGPoint(x: base.x, y: base.y - lh)
        }
    }

    /// Width of one hint line (the hint label's font, size and letter spacing).
    static func hintWidth(_ t: String) -> CGFloat {
        NSAttributedString(string: t, attributes: [.font: Fonts.font(Fonts.semibold, 14), .kern: CGFloat(1.1)]).size().width
    }

    /// Two lines of a long hint: at « · » (dropped) or « — » (kept at the end of the first line), whichever leaves the
    /// shorter longer line; else at the space nearest the middle. «GRID HITS EVERY 6 SEC —» / «WEAKER AT THE EDGE, …».
    static func splitHint(_ t: String) -> (String, String) {
        let c = Array(t), n = c.count
        var best = (score: Int.max, end: -1, start: -1)
        if n >= 3 {
            for i in 0...(n - 3) where c[i] == " " && c[i + 2] == " " && (c[i + 1] == "·" || c[i + 1] == "—") {
                let end = c[i + 1] == "—" ? i + 2 : i
                let score = max(end, n - (i + 3))
                if score < best.score { best = (score, end, i + 3) }
            }
        }
        if best.end < 0 {
            for i in 0..<n where c[i] == " " {
                let score = max(i, n - i - 1)
                if score < best.score { best = (score, i, i + 1) }
            }
        }
        if best.end <= 0 || best.start >= n { return (t, "") }
        return (String(c[0..<best.end]), String(c[best.start...]))
    }

    // ---------------------------------------------------------------- per frame
    /// `keyboard`: the last input was a hardware keyboard (the coach names keys, no ghost thumb).
    func update(game: Game, dt: Float, projection: HUDProjection, input: InputController, keyboard: Bool = false) {
        let P = game.player
        // fast-changing numbers at 10 Hz (glyph labels: a new value only re-points sprites)
        textT -= dt
        if textT <= 0 {
            textT = 0.1
            killsVal.set(L10n.num(game.kills))   // en grouping, as on the report: 3,797
            hpVal.set("\(Int(max(0, P.hp).rounded(.up)))")
            let combo = game.comboShown
            if combo != comboLast {
                comboVal.set(combo > 0 ? L10n.ui(.hudCombo, .int(combo)) : "")
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
        let ok = game.objectiveKey
        if ok != objKey {
            objKey = ok
            let st = game.objectiveStyle
            if st != objStyle { applyObjStyle(st) }
            // (B3: the boss style's caption is the boss's name — a generic boss bar, the Queen's today)
            let capName: NameRef? = st == .boss ? game.boss.kind.name : nil
            if capName != objCapName {
                objCapName = capName
                objCap.set(L10n.upper(capName.map { L10n.name($0) } ?? L10n.ui(.hudObjective)))
                TextFit.scale(objCap, objTextRoom, minScale: HUD.objMinScale)
                if AppLog.diagnostics { AppLog.info("hud objective caption «\(objCap.text)»" + (capName != nil ? " (boss bar)" : "")) }
            }
            objText.set(L10n.upper(game.objective.map { L10n.string($0) } ?? ""))
            TextFit.scale(objText, objTextRoom, minScale: HUD.objMinScale)
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
        var src = HintSource.none
        var urgent = false
        if let c = game.contextHint { src = .text(c.text); urgent = c.urgent } else if game.showControlHint && !P.downed { src = .controls }
        if src != hintSource {
            hintSource = src
            switch src {
            case .none: hintText = ""
            case .controls: hintText = L10n.upper(L10n.ui(.hudControlHint))
            case .text(let t): hintText = L10n.upper(L10n.string(t))
            }
            fitHint()
        }
        if urgent != hintUrgent {
            hintUrgent = urgent
            hint.color = urgent ? UIPalette.red : UIPalette.amber
            hint2.color = hint.color
        }
        // H1: a new hint line, or a new banner, takes its place (in a hold: where it hides least of the squad and the deck)
        if hintPlace || (hintAtTop && game.stage != .hold) { placeHint(game, projection) }
        if bannerPlace && !warming { bannerPlace = false; placeBanner(game, projection) }
        // under a menu (pause, level-up cards, report) the hint and the toasts wait: they would peek out between or
        // above its boxes
        if toastRoot.isHidden != covered { toastRoot.isHidden = covered; toastRootL.isHidden = covered }
        // H1: a calm hint steps aside (0.15 s) while a banner over it is up — read one after the other, not stacked (the
        // hold's «DIG IN» and its lift-pulse hint); an urgent one never does (the banner keeps above it)
        let over = !urgent && !hintText.isEmpty && (bannerUpRect.map { b in
            let r = hintRects()
            return b.intersects(hintAtTop ? r.top : r.bottom)
        } ?? false)
        hintAside = over ? max(0, hintAside - CGFloat(dt / 0.15)) : min(1, hintAside + CGFloat(dt / 0.15))
        let ha: CGFloat = covered ? 0 : (urgent ? (sinf(game.time * 7.85) > 0 ? 1 : 0.35) : hintAside)
        hint.node.alpha = ha
        hint2.node.alpha = ha

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
            // the left column under the stats panel (the coach card stays clear of it: coachMaxWidth)
            var y = 10 + insets.top + 40 + 8
            for (k, r) in squad.enumerated() {
                let on = shown & (1 << k) != 0
                r.node.isHidden = !on
                if on { r.node.position = hp(max(16, insets.left), y); y += Geo.rowStep }
            }
        }
        hpBar.set(CGFloat(P.hp / max(1, P.maxHp)))
        if game.xpLevel != levelShown { levelShown = game.xpLevel; lvl.set(L10n.upper(L10n.ui(.hudLevel, .int(game.xpLevel)))) }
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

        // toasts (H1): the queue hands out what may show now, each new one takes the column where it hides least, a
        // column under the banner steps aside until it has gone
        updateToasts(game: game, dt: dt, projection: projection)
        // banner (2.4 s, 3.4 s with Reduce Motion)
        bannerT += dt
        if let p = pinnedBanner, !warming {
            // (re-shown when the cover's warm-up banner replaced it), held at full strength
            if bannerTitle.text != L10n.upper(p.0) || bannerSub.text != L10n.upper(p.1) { showBanner(title: p.0, subtitle: p.1, teal: p.2) }
            bannerT = 0.6
        }
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
        horde.alpha = CGFloat(hordeA * (0.85 + 0.15 * sinf(wall * 3.1)) * 0.7)
        // full-screen quads: skip the fill entirely while invisible
        for n in overlays { n.isHidden = n.alpha < 0.004 }
        banner.isHidden = banner.alpha < 0.004

        plates.update(game: game, projection: projection, size: size)
        updateMarker(game: game, projection: projection)
    }

    private var squadShown = -1
    private var squadBand: CGFloat = -1

    /// «Учебная высадка»: the card for the current step (touch or keyboard text), under it the alerts and toasts; the
    /// ghost thumb on the control of the step, its target pulsing (wall time; slower with Reduce Motion).
    private func updateCoach(_ game: Game, keyboard: Bool) {
        coachCard.reducedMotion = reducedMotion
        ghost.reducedMotion = reducedMotion
        let target = warming ? nil : game.coach.target
        if let t = target {
            let step = game.coach.step
            let top = objBottom + 2
            // the card text is built only when the step, the input mode or the layout changes (no per-frame strings)
            if step != cardStep || keyboard != cardKeyboard || layoutGen != cardLayoutGen || !coachCard.visible {
                cardStep = step; cardKeyboard = keyboard; cardLayoutGen = layoutGen
                let text = L10n.upper(L10n.string(CoachText.text(step: step, cls: game.player.cls, keyboard: keyboard)))
                coachCard.show(step: step, text: text, centerX: 0, top: hp(0, top).y, maxWidth: coachMaxWidth)
            }
            coachCard.update(top: hp(0, top).y)
            let bb = top + coachCard.height
            if bb != bandBottom { bandBottom = bb; placeBand() }
            // (a layout — rotation, safe area — moves the sticks and buttons: the ghost follows them)
            if t != coachTarget || keyboard != coachKeyboard || layoutGen != ghostLayoutGen {
                coachTarget = t
                coachKeyboard = keyboard
                ghostLayoutGen = layoutGen
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
    private var cardStep = -1, cardKeyboard = false, cardLayoutGen = -1, ghostLayoutGen = -1
    /// Bumped by every layout (rotation, safe area): the coach card and the ghost thumb are laid out again.
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
        if dm != markerDist { markerDist = dm; markerLabel.set(L10n.ui(.hudDistance, .int(dm))) }
        let mx = size.width / 2 - 40, myTop = size.height / 2 - max(bandBottom, hintTopBottom) - 30, myBot = -size.height / 2 + 150
        // VX-5: the block holding the dash and the ability button (+ 20 pt): an on-screen marker there counts as off screen,
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
        // H1: where it would be (the toasts' side choice keeps clear of it) — then never on a toast: inside a toast (+ the
        // marker's own reach: the arrow ± 22 pt, the distance under it) it stops where its ray from the screen centre
        // enters that toast, as an edge arrow there (also when it was over its target: the target is under the toast)
        let p0 = marker.position
        markerBox = CGRect(x: p0.x - 22 + size.width / 2, y: size.height / 2 - p0.y - 12, width: 44, height: 42)
        markerOverTarget = inside
        var p = p0
        // (not behind the loading cover: the warm-up's toasts are no toasts)
        for b in warming ? [] : toastRects() {
            let r = CGRect(x: b.minX - 22, y: b.minY - 12, width: b.width + 44, height: b.height + 42)
            guard r.contains(p) else { continue }
            let len = (p.x * p.x + p.y * p.y).squareRoot()
            guard len > 1 else { continue }
            let dx = p.x / len, dy = p.y / len
            // the ray t·(dx, dy) enters r at the latest of its two slab entries
            var tIn: CGFloat = 0
            if abs(dx) > 1e-4 { tIn = max(tIn, min(r.minX / dx, r.maxX / dx)) }
            if abs(dy) > 1e-4 { tIn = max(tIn, min(r.minY / dy, r.maxY / dy)) }
            guard tIn > 1 && tIn < len else { continue }
            p = CGPoint(x: dx * (tIn - 1), y: dy * (tIn - 1))
            markerArrow.zRotation = CGFloat(atan2(Double(dy), Double(dx))) - .pi / 2
            markerArrow.setScale(1)
        }
        if p != p0 {
            marker.position = p
            if AppLog.diagnostics && !markerYielded {
                AppLog.info(String(format: "hud marker kept off a toast: (%.0f, %.0f) → (%.0f, %.0f)", p0.x, p0.y, p.x, p.y))
            }
        }
        markerYielded = p != p0
    }

    /// The marker's box where it would be without the toasts (view points), whether it was over its target (H1).
    private var markerBox = CGRect.zero
    private var markerOverTarget = false
    private var markerYielded = false

    func setDebug(_ text: String) {
        debugLabel.node.isHidden = !showDebug
        if showDebug { debugLabel.set(text) }
    }
}

// ================================================================
//  NAMEPLATES — callsign + HP bar over each marine (web .plate),
//  stacked upward when they overlap. VX-2 (WP4): while the ground HP
//  arcs are on (GroundGlyphs.hpArcs — armour pips under every marine,
//  the player's magazine / heat as the arc's inner line) a plate shows
//  only while its marine is downed / being revived, or for 1.5 s after
//  it took damage.
// ================================================================
final class Nameplates {
    let root = SKNode()
    private final class Plate {
        let node = SKNode()
        let name: Label
        let bar: Bar
        let seg: DashBar?
        let revive = SKSpriteNode(color: UIPalette.teal, size: CGSize(width: 76, height: 2))
        let player: Bool
        let width: CGFloat
        init(name text: String, player: Bool) {
            let w: CGFloat = player ? 96 : 76
            self.player = player
            width = w
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

    /// How far plate `k` sits over the plate it is stacked on: a squadmate's plate ends 19 pt under its anchor (bar), the
    /// player's 26 pt (magazine dashes), a downed marine's 2–5 pt lower (revive bar); 5–7 pt clear of the name below.
    private func plateRise(over k: Int, _ m: Marine) -> CGFloat {
        (plates[k].player ? 31 : 26) + (m.downed ? 4 : 0)
    }
    private var px = [CGFloat](repeating: 0, count: 4), py = [CGFloat](repeating: 0, count: 4)
    // VX-2: which plates show this frame, until when after a hit, the armour last frame
    private var shown = [Bool](repeating: true, count: 4)
    private var shownUntil = [Float](repeating: 0, count: 4)
    private var lastHp = [Float](repeating: -1, count: 4)

    func setSquad(_ marines: [Marine]) {
        for p in plates { p.node.removeFromParent() }
        shown = [Bool](repeating: true, count: max(4, marines.count))
        shownUntil = [Float](repeating: 0, count: max(4, marines.count))
        lastHp = [Float](repeating: -1, count: max(4, marines.count))
        plates = marines.map { m in
            let p = Plate(name: L10n.upper(L10n.name(m.name)), player: m.isPlayer)
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
            if GroundGlyphs.hpArcs {
                if lastHp[k] >= 0 && m.hp < lastHp[k] - 0.01 { shownUntil[k] = game.time + 1.5 }
                lastHp[k] = m.hp
                shown[k] = m.downed || game.time < shownUntil[k]
            } else {
                shown[k] = true
            }
        }
        // overlapping plates stack upward (PLATE_GAP 26 for a squadmate's plate; the player's hangs lower — its magazine
        // dashes, a downed marine's revive bar — so it rises further and stays clear of the name under it); near the
        // objective box they spread sideways, bar ends 6 pt apart
        for _ in 0..<6 {
            for a in 0..<n where shown[a] {
                for b in (a + 1)..<max(a + 1, n) where shown[b] {
                    let dx = px[a] - px[b]
                    let wide = (plates[a].width + plates[b].width) / 2 + 6
                    if abs(dx) >= wide { continue }
                    let dy = py[a] - py[b]
                    let up = dy > 0 ? a : b, lo = up == a ? b : a
                    let gap = plateRise(over: up, game.marines[up])
                    if abs(dy) >= gap { continue }
                    if py[lo] + gap <= topLimit { py[up] = py[lo] + gap } else {
                        let l = dx < 0 ? a : b, r = l == a ? b : a, mid = (px[a] + px[b]) / 2
                        px[l] = mid - wide / 2; px[r] = mid + wide / 2
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
            if p.node.isHidden == shown[k] { p.node.isHidden = !shown[k] }
            if !shown[k] { continue }
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
