import Foundation

// ================================================================
//  KELVIN-9 MK II (Stage 1 R5; design.md §1.2.1, tech.md §2.2) — the
//  hand-made station gets its overhead: the route set authored here
//  (`OverheadLayout.kelvinMk2`) and R6's interactive props
//  (`PropLayout.kelvin`) laid over the v1.0 decks, rails and beacons.
//  `KelvinStation.mk2` is the classic mission's station since R5: the app
//  plays it and the calibration gate's classic rows run on it; the bare
//  `KelvinStation()` stays the v1.0 layout (the hidden legacy row, the
//  core tests of the mechanics, the generator's seed 0).
//  The routes, as the camera sees them from the bottom right (screen-up is
//  world −x −z; «far» rails are the −x / −z ones, whose image falls into
//  the void — concept-station README):
//    1 SPINE RACK   4.5 m on the far rail of the pad → hub bridge (R2's
//                   slice: deck post on the pad, abyss riser, duct mouth;
//                   R6's valve 0), a cable span over the hub (the one thin
//                   crossing of that junction), the rack on the far rail of
//                   the hub → A catwalk to a deck post on A's deck, a second
//                   duct mouth over the void
//    3 STAIR CHUTE  the rack turns along the hub's far corner, a ladder
//                   tray runs down the far rail of the hub → plaza stairs
//                   (4 m over the top step, 6 m over the plaza at its foot)
//    2 PLAZA GANTRY 5 m along the plaza's far edge: catwalks over the void
//                   with perches at both corners, a pipe over the head of
//                   the stairs down to the lift (R6's valve 3), a duct mouth;
//                   the C and B racks (4.5 m, the far rails of the plaza → C
//                   and plaza → B catwalks) join its corners; the CABLE
//                   CROSS — one bundle over the plaza to the chute's foot
//    5 HEAT EXCHANGER  beacon B's far rail, 4 m (R6's valves 1 and 2)
//    4 BEACON A MAST   a lattice mast at A's far corner, two guy cables to
//                   A's pillars along its far and west edges
//    8 LOOP TRAYS   3.5 m on the far rails of the sloped west / east loops
//    7 LIFT CABLES  four masts out in the void beyond the lift's far half,
//                   a cable from each down to 3 m over the lift deck just
//                   outside its rim (the hold's packs come down them; the
//                   near half — the extraction camera's — stays clear)
//    9 UPPER TRUSS  decoration, built by the renderer over the big
//                   beacon-free decks (the hub and the plaza)
//  Not here: the design's crane rail over C with its moving hook block (a
//  moving overhead: the Bay 4 arena's system).
//  Every route keeps the rules `OverheadCheck` holds (3–9 m over the deck it
//  serves, ≥ 6.1 m from the beacons, only thin kinds over walkable deck,
//  ≤ 4 % footprint) and the full set's 150–450 m band (295 m); its golden
//  hash is pinned in KelvinMk2Tests.
// ================================================================

extension OverheadLayout {
    /// «Кельвин-9» Mk II's overhead (design §1.2.1): 45 nodes, 37 edges, 295 m; 3 duct mouths, 2 authored perches, 16
    /// spawn entries. Nodes 0–2 and 4 are R2's demo slice (`kelvinSlice`), the Spine Rack's first stretch.
    public static let kelvinMk2: OverheadLayout = {
        var o = OverheadLayout()
        // 1 · the Spine Rack (4.5 m over the 0 deck); the slice's nodes first
        let spinePad = o.addNode(24, 4.5, 26.4, .deckPost, riserFrom: 0)
        let spineDuct1 = o.addNode(19, 4.5, 26.4, .joint)
        let spineRiser1 = o.addNode(14, 4.5, 26.4, .abyssRiser, riserFrom: -5)
        let spineHubE = o.addNode(6.6, 4.5, 26.4, .joint)
        let duct1 = o.addNode(19, 5, 23.4, .ductMouth)
        let spineHubW = o.addNode(-8.6, 4.5, 24.4, .joint)
        let spineDuct2 = o.addNode(-13, 4.5, 24.4, .joint)
        let duct2 = o.addNode(-13, 5, 21.4, .ductMouth)
        let spineRiser2 = o.addNode(-17, 4.5, 24.4, .abyssRiser, riserFrom: -5)
        let spineA = o.addNode(-25.6, 4.5, 24.4, .deckPost, riserFrom: 0)
        // 3 · the hub's far corner and the Stair Chute
        let hubCorner = o.addNode(-8.6, 4.5, 17.4, .joint)
        let chuteTop = o.addNode(-4.6, 4, 17.4, .joint)
        let chuteFoot = o.addNode(-4.6, 3, 2.6, .abyssRiser, riserFrom: -9)
        // 2 · the C rack, the plaza gantry, the B rack (the −3 deck)
        let cDeck = o.addNode(-27.8, 1.5, -9.6, .deckPost, riserFrom: -3)
        let cRiser = o.addNode(-19.5, 1.5, -9.6, .abyssRiser, riserFrom: -9)
        let cPlaza = o.addNode(-12.4, 1.5, -9.6, .joint)
        let gantryW = o.addNode(-12.4, 2, -12.4, .perch)
        let gantryStairW = o.addNode(-6.6, 2, -12.4, .joint)
        let gantryStairE = o.addNode(0.6, 2, -12.4, .joint)
        let gantryE = o.addNode(10.4, 2, -12.4, .perch)
        let duct3 = o.addNode(-15.4, 2.5, -12.4, .ductMouth)
        let bPlaza = o.addNode(10.4, 1.5, -8.6, .joint)
        let bRiser = o.addNode(16, 1.5, -8.6, .abyssRiser, riserFrom: -9)
        let bCorner = o.addNode(21.4, 1.5, -8.6, .joint)
        let bDeck = o.addNode(23.8, 1.5, -8.6, .deckPost, riserFrom: -3)
        // 5 · beacon B's heat exchanger
        let hxW = o.addNode(21.4, 1, -16.3, .joint)
        let hxMid = o.addNode(30, 1, -16.3, .joint)
        let hxE = o.addNode(38.6, 1, -16.3, .abyssRiser, riserFrom: -9)
        // 4 · beacon A's mast and its guys (deck posts on A's pillars)
        let mastA = o.addNode(-40.6, 6, 17.4, .mast, riserFrom: -3)
        let mastAGuyE = o.addNode(-24.6, 3.5, 18.6, .deckPost, riserFrom: 0)
        let mastAGuyS = o.addNode(-39.6, 3.5, 35.4, .deckPost, riserFrom: 0)
        // 8 · the loop trays
        let loopWS = o.addNode(-36.6, 0.5, 0.6, .joint)
        let loopWRiser = o.addNode(-36.6, 2, 9, .abyssRiser, riserFrom: -9)
        let loopWN = o.addNode(-36.6, 3.5, 17.4, .joint)
        let loopES = o.addNode(29.4, 0.5, 0.6, .joint)
        let loopERiser = o.addNode(29.4, 2, 11, .abyssRiser, riserFrom: -9)
        let loopEN = o.addNode(29.4, 3.5, 21.4, .joint)
        // 7 · the lift cables: masts 17 m and rim anchors 10.8 m from the lift's centre at 165°, 205°, 245°, 285° (from +x
        // toward +z; 1/64 m literals — no trigonometry in the data)
        let liftMast165 = o.addNode(-19.421875, 2.5, -37.59375, .mast, riserFrom: -10)
        let liftRim165 = o.addNode(-13.4375, -3, -39.203125, .joint)
        let liftMast205 = o.addNode(-18.40625, 2.5, -49.1875, .mast, riserFrom: -10)
        let liftRim205 = o.addNode(-12.78125, -3, -46.5625, .joint)
        let liftMast245 = o.addNode(-10.1875, 2.5, -57.40625, .mast, riserFrom: -10)
        let liftRim245 = o.addNode(-7.5625, -3, -51.78125, .joint)
        let liftMast285 = o.addNode(1.40625, 2.5, -58.421875, .mast, riserFrom: -10)
        let liftRim285 = o.addNode(-0.203125, -3, -52.4375, .joint)
        // edges
        o.addEdge(spinePad, spineDuct1, .pipe)
        o.addEdge(spineDuct1, spineRiser1, .pipe)
        o.addEdge(spineRiser1, spineHubE, .pipe)                  // (R6's valve 0 at x 13)
        o.addEdge(duct1, spineDuct1, .duct)
        o.addEdge(spineHubE, spineHubW, .cable, sag: 0.45)       // over the hub
        o.addEdge(spineHubW, spineDuct2, .pipe)
        o.addEdge(spineDuct2, spineRiser2, .pipe)
        o.addEdge(spineRiser2, spineA, .pipe)
        o.addEdge(duct2, spineDuct2, .duct)
        o.addEdge(spineHubW, hubCorner, .pipe)
        o.addEdge(hubCorner, chuteTop, .pipe)
        o.addEdge(chuteTop, chuteFoot, .tray)
        o.addEdge(cDeck, cRiser, .pipe)
        o.addEdge(cRiser, cPlaza, .pipe)
        o.addEdge(cPlaza, gantryW, .pipe)
        o.addEdge(gantryW, gantryStairW, .catwalk)
        o.addEdge(gantryStairW, gantryStairE, .pipe)             // over the head of the lift stairs (R6's valve 3)
        o.addEdge(gantryStairE, gantryE, .catwalk)
        o.addEdge(duct3, gantryW, .duct)
        o.addEdge(gantryE, bPlaza, .pipe)
        o.addEdge(bPlaza, bRiser, .pipe)
        o.addEdge(bRiser, bCorner, .pipe)
        o.addEdge(bCorner, bDeck, .pipe)
        o.addEdge(gantryE, chuteFoot, .cable, sag: 0.6)          // the Cable Cross over the plaza
        o.addEdge(bCorner, hxW, .pipe)
        o.addEdge(hxW, hxMid, .pipe)                             // (R6's valve 1 at x 26)
        o.addEdge(hxMid, hxE, .pipe)                             // (R6's valve 2 at x 34)
        o.addEdge(mastA, mastAGuyE, .cable, sag: 0.5)
        o.addEdge(mastA, mastAGuyS, .cable, sag: 0.5)
        o.addEdge(loopWS, loopWRiser, .tray)
        o.addEdge(loopWRiser, loopWN, .tray)
        o.addEdge(loopES, loopERiser, .tray)
        o.addEdge(loopERiser, loopEN, .tray)
        o.addEdge(liftMast165, liftRim165, .cable, sag: 0.3)
        o.addEdge(liftMast205, liftRim205, .cable, sag: 0.3)
        o.addEdge(liftMast245, liftRim245, .cable, sag: 0.3)
        o.addEdge(liftMast285, liftRim285, .cable, sag: 0.3)
        return o
    }()
}

/// Named nodes of `OverheadLayout.kelvinMk2` the demos and tests use.
public enum KelvinMk2 {
    /// The Spine Rack's abyss riser over the pad → hub bridge (R2's slice node 2) and the duct mouth beside it (node 4).
    public static let spineRiser = 2, bridgeDuct = 4
    /// The hub → A duct mouth, the plaza gantry's duct mouth.
    public static let hubDuct = 7, plazaDuct = 20
    /// The plaza gantry's perches (its far corners).
    public static let gantryPerches = [16, 19]
    /// The chute's foot (an abyss riser at the hub → plaza stairs), the C, B and heat-exchanger risers, beacon A's mast.
    public static let chuteFoot = 12, cRiser = 14, bRiser = 22, hxRiser = 27, mastA = 28
    /// The lift masts (the hold's cables).
    public static let liftMasts = [37, 39, 41, 43]
    /// The full set's length band (tech.md §2.2).
    public static let lengthBand: ClosedRange<Float> = 150...450
}

extension KelvinStation {
    /// «Кельвин-9» Mk II — the classic mission's station since Stage 1 R5: the v1.0 decks with the overhead routes
    /// (`OverheadLayout.kelvinMk2`) and the interactive props (`PropLayout.kelvin`: seven light circuits, four steam valves
    /// on the Mk II pipes, a supply locker) laid.
    public static var mk2: KelvinStation { KelvinStation(overhead: .kelvinMk2, props: .kelvin) }
}
