import IceHiveCore

// ================================================================
//  TOAST QUEUE (Stage 2 H1 «the first minute's HUD») — what the toast
//  column shows, and when. The game raises a toast the moment
//  something happens: in the first minute of a mission that was up to
//  six first-sighting tips with the upgrade names and the squad's radio
//  in one go, stacked two or three deep over the banner. The queue
//  sorts every toast into one of three lanes:
//    threat — a squadmate pinned or down, the player down: shown at
//             once (or the moment a banner over the column is gone),
//             dropped only when the threat is over by then (the mate
//             freed / back up) — the squad row shows a downed mate
//             meanwhile;
//    tip    — a first sighting (toast.tip.*): ONE at a time, in the
//             order they came, `tipGap` s apart, never under a banner
//             or a menu, nor while the hint line shows a threat to the
//             player («Pinned — dash!», «You're down»: those jump the
//             line). A tip is shown only while its thing is there (a
//             duct mouth rattling, a spitter perched, a Dropper or its
//             ring, a ready valve / a dark breaker / a stocked locker
//             within reach, a live bug of its kind — HUD.thing). A tip
//             whose moment has passed when its turn comes steps out of
//             the line and waits; when its thing is back (the next
//             rattle, the next perch, …) it takes its old place again.
//             Nothing is thrown away: a tip stays unseen only if its
//             thing never comes back that mission;
//    bark   — everything else (upgrade names, «Lights up»,
//             «Resupplied», «Got it off you», …): shown at once, one at
//             a time (a newer bark replaces one shown ≥ `barkMin` s),
//             dropped after `barkStale` s in the line — it reports a
//             change the screen shows anyway (the cards, the lamps, the
//             squad rows).
//  Pure logic (no SpriteKit): the HUD posts the game's toasts, tells it
//  each frame what is on screen, and draws what it hands out.
// ================================================================
final class ToastQueue {
    enum Lane: Int { case threat, tip, bark }

    struct Item {
        let text: GameText
        let kind: ToastKind
        let lane: Lane
        let seq: Int
        /// Seconds since it was posted.
        var age: Float = 0
        /// A tip whose thing was gone at its turn: out of the line until the thing is back.
        var parked = false
    }

    /// A toast to draw now: `life` s on screen; `waited` s in the line.
    struct Show {
        let text: GameText
        let kind: ToastKind
        let lane: Lane
        let life: Float
        let waited: Float
    }

    /// What the HUD knows this frame.
    struct State {
        /// A banner over the column, a menu over the HUD, the loading cover's warm-up: nothing new starts.
        var hold = false
        /// A tip toast is still on screen.
        var tipShown = false
        /// Seconds the newest bark toast has been on screen (-1: none on screen).
        var barkShownFor: Float = -1
        /// The hint line shows a threat to the player («Pinned — dash!», «You're down»).
        var threatHint = false
        init(hold: Bool = false, tipShown: Bool = false, barkShownFor: Float = -1, threatHint: Bool = false) {
            self.hold = hold; self.tipShown = tipShown; self.barkShownFor = barkShownFor; self.threatHint = threatHint
        }
    }

    /// A tip on screen alone / with another tip waiting behind it (≈ 1.5 × the time to read a two-line tip).
    static let tipLife: Float = 4.5
    static let tipLifeBusy: Float = 3.6
    /// Empty tip slot between two tips (a new message reads as new).
    static let tipGap: Float = 0.8
    static let barkLife: Float = 3.2
    static let threatLife: Float = 4.5
    /// A bark is up at least this long before a newer one replaces it.
    static let barkMin: Float = 1.0
    static let barkStale: Float = 3.0
    static let threatStale: Float = 4.0
    /// How often a parked tip looks for its thing.
    static let parkPoll: Float = 0.25

    private(set) var items: [Item] = []
    private var seq = 0
    private var gap: Float = 0
    private var tipWasShown = false
    private var pollT: Float = 0
    /// Diagnostics: one line per decision («hud tip: …»).
    var log: ((String) -> Void)? = nil

    static func lane(_ id: TextID) -> Lane {
        switch id {
        case .toastMatePinned, .toastMateDown, .toastPlayerDown: return .threat
        default: return id.rawValue.hasPrefix("toast.tip.") ? .tip : .bark
        }
    }

    func post(_ text: GameText, kind: ToastKind) {
        seq += 1
        let it = Item(text: text, kind: kind, lane: ToastQueue.lane(text.id), seq: seq)
        items.append(it)
        log?("queued \(ToastQueue.name(it.lane)) \(text.id.rawValue) (line \(items.count))")
    }

    /// A new mission: nothing carries over.
    func reset() {
        items.removeAll()
        gap = 0
        tipWasShown = false
        pollT = 0
    }

    /// What to show this frame. `fresh(text, lane)`: its thing is there now (a threat: still pinned / down; a tip: its
    /// thing — see the header; a bark: always).
    func update(dt: Float, state s: State, fresh: (GameText, Lane) -> Bool) -> [Show] {
        for k in items.indices { items[k].age += dt }
        // the gap after a tip runs once it has gone, while the screen is free to show
        if tipWasShown && !s.tipShown { gap = ToastQueue.tipGap }
        tipWasShown = s.tipShown
        if !s.hold && gap > 0 { gap -= dt }
        // parked tips look for their thing
        pollT -= dt
        if pollT <= 0 {
            pollT = ToastQueue.parkPoll
            for k in items.indices where items[k].parked && fresh(items[k].text, .tip) {
                items[k].parked = false
                log?("back \(items[k].text.id.rawValue): its thing is there again (\(ToastQueue.fmt(items[k].age)) s after it came)")
            }
        }
        var out: [Show] = []
        // threats: at once, unless over
        var k = 0
        while k < items.count {
            let it = items[k]
            guard it.lane == .threat else { k += 1; continue }
            if !fresh(it.text, .threat) || it.age > ToastQueue.threatStale {
                log?("dropped \(it.text.id.rawValue): the threat is over (\(ToastQueue.fmt(it.age)) s)")
                items.remove(at: k)
                continue
            }
            if s.hold { k += 1; continue }
            out.append(Show(text: it.text, kind: it.kind, lane: .threat, life: ToastQueue.threatLife, waited: it.age))
            items.remove(at: k)
        }
        // barks: the oldest, once the one on screen has been read
        var barkFree = s.barkShownFor < 0 || s.barkShownFor >= ToastQueue.barkMin
        k = 0
        while k < items.count {
            let it = items[k]
            guard it.lane == .bark else { k += 1; continue }
            if it.age > ToastQueue.barkStale {
                log?("dropped \(it.text.id.rawValue): stale after \(ToastQueue.fmt(it.age)) s")
                items.remove(at: k)
                continue
            }
            if s.hold || !barkFree { k += 1; continue }
            out.append(Show(text: it.text, kind: it.kind, lane: .bark, life: ToastQueue.barkLife, waited: it.age))
            items.remove(at: k)
            barkFree = false
        }
        // tips: one at a time, in the order they came, while their thing is there
        if !s.hold && !s.tipShown && gap <= 0 && !s.threatHint {
            k = 0
            while k < items.count {
                let it = items[k]
                if it.lane != .tip || it.parked { k += 1; continue }
                if !fresh(it.text, .tip) {
                    items[k].parked = true
                    log?("parked \(it.text.id.rawValue): its moment passed (\(ToastQueue.fmt(it.age)) s in the line)")
                    k += 1
                    continue
                }
                items.remove(at: k)
                let more = items.contains { $0.lane == .tip && !$0.parked }
                out.append(Show(text: it.text, kind: it.kind, lane: .tip, life: more ? ToastQueue.tipLifeBusy : ToastQueue.tipLife,
                                waited: it.age))
                break
            }
        }
        return out
    }

    /// Tips waiting / parked (the heartbeat's `hud tips` line).
    var waitingTips: Int { items.filter { $0.lane == .tip && !$0.parked }.count }
    var parkedTips: Int { items.filter { $0.lane == .tip && $0.parked }.count }

    static func name(_ l: Lane) -> String {
        switch l {
        case .threat: return "threat"
        case .tip: return "tip"
        case .bark: return "bark"
        }
    }

    static func fmt(_ x: Float) -> String {
        let t = Int((x * 10).rounded())
        return "\(t / 10).\(abs(t % 10))"
    }
}
