import Foundation
import IceHiveCore

// ================================================================
//  OVERHEAD SHOWCASE — the route set the overhead demo lays on
//  «Кельвин-9» (Stage 1 R3: every kind of the layer in one frame round
//  the pad → hub bridge, where the squad stands). It extends R2's demo
//  slice (OverheadLayout.kelvinSlice: nodes 0–4 keep their indices — the
//  abyss riser 2 and the duct mouth 4 are the demo's pack entries):
//    · the Spine rack, 4.5 m, 0.6 m outside the bridge's far (−z) rail,
//      with the slice's abyss riser, deck posts and duct mouth;
//    · two cantilever arms from far-side posts (x 17, 9.5) reaching
//      3.4 m over the walkway, a cable bundle between their tips
//      (5.3 m, 0.45 m sag): the bugs from the duct mouth take it and
//      wait over the squad (the one thin crossing per screen);
//    · a pipe bridge rising out over the void (x 12 → 10, z 26 → 12,
//      6.3 m) that runs on into the dark;
//    · a maintenance catwalk over the void to an abyss riser platform;
//    · the Stair Chute: a tray along the hub → plaza stairs' far rail
//      (4 → 1.2 m) fed from a hub deck post by a short cable.
//  The classic mission plays the real Kelvin-9 Mk II set since package
//  R5 (OverheadLayout.kelvinMk2); this showcase stays the overhead's
//  look-dev frame. GameScene logs routeCheck.
// ================================================================
enum OverheadShowcase {
    static let layout: OverheadLayout = {
        var o = OverheadLayout()
        // R2's slice (indices 0–4)
        let pad = o.addNode(24, 4.5, 26.4, .deckPost, riserFrom: 0)
        let duct = o.addNode(19, 4.5, 26.4, .joint)
        let riser = o.addNode(14, 4.5, 26.4, .abyssRiser, riserFrom: -5)
        let hub = o.addNode(4, 4.5, 26.4, .deckPost, riserFrom: 0)
        let mouth = o.addNode(19, 5.0, 23.4, .ductMouth)
        // the rack's other joints, the arms' tips, the pipe bridge, the catwalk, the stair chute
        let cat = o.addNode(21, 4.5, 26.4, .joint)
        let armA = o.addNode(17, 4.5, 26.4, .joint)
        let tipA = o.addNode(17, 5.3, 30.4, .gantry)
        let bridge = o.addNode(12, 4.5, 26.4, .joint)
        let armB = o.addNode(9.5, 4.5, 26.4, .joint)
        let tipB = o.addNode(9.5, 5.3, 30.4, .gantry)
        let bridgeEnd = o.addNode(10, 6.3, 12, .joint)
        let catEnd = o.addNode(18.5, 4.7, 19.4, .abyssRiser, riserFrom: -6)
        let chuteTop = o.addNode(-4.6, 4.0, 20, .deckPost, riserFrom: 0)
        let chute = o.addNode(-4.6, 3.6, 17.2, .joint)
        let chuteEnd = o.addNode(-4.6, 1.2, 4, .abyssRiser, riserFrom: -8)
        // the Spine rack (pad → hub)
        o.addEdge(pad, cat, .pipe)
        o.addEdge(cat, duct, .pipe)
        o.addEdge(duct, armA, .pipe)
        o.addEdge(armA, riser, .pipe)
        o.addEdge(riser, bridge, .pipe)
        o.addEdge(bridge, armB, .pipe)
        o.addEdge(armB, hub, .pipe)
        o.addEdge(mouth, duct, .duct)
        // the arms and the cable over the walkway
        o.addEdge(armA, tipA, .pipe)
        o.addEdge(armB, tipB, .pipe)
        o.addEdge(tipA, tipB, .cable, sag: 0.45)
        // the pipe bridge, the catwalk, the stair chute
        o.addEdge(bridge, bridgeEnd, .pipe)
        o.addEdge(cat, catEnd, .catwalk)
        o.addEdge(chuteTop, chute, .cable, sag: 0.1)
        o.addEdge(chute, chuteEnd, .tray)
        return o
    }()
}
