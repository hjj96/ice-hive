import SpriteKit
import UIKit
import IceHiveCore

// ================================================================
//  LAYOUT SIZES — `-demo layout` (LAND): every screen laid out on the
//  four landscape phones the app is designed for, with their landscape
//  safe areas, on detached screen instances (nothing is drawn), each
//  through LayoutCheck: «layout ok|FAIL <screen> WxH <phone> <case>».
//    874 × 402  6.1" Dynamic Island (iPhone 14–17 Pro)  62 | 62, bottom 20
//    932 × 430  6.7" Dynamic Island (Plus / Pro Max)    59 | 59, bottom 20
//    844 × 390  6.1" notch (iPhone 12–14, 16e)          47 | 47, bottom 20
//    667 × 375  iPhone SE 2 / 3                          no insets
//  (iOS reports the Dynamic Island / notch inset on both sides in
//  landscape.) Screens: the title (fresh, returning, Кошмар), the HUD
//  (its fixed elements and the room the coach card, toasts and hint
//  take), the pause, the level-up cards (the longest descriptions), the
//  four report fixtures. CI runs it in the main simulator and fails on
//  any FAIL line.
// ================================================================
enum LayoutSizes {
    struct Phone {
        let name: String
        let size: CGSize
        let insets: UIEdgeInsets
    }

    static let phones: [Phone] = [
        Phone(name: "6.1", size: CGSize(width: 874, height: 402), insets: UIEdgeInsets(top: 0, left: 62, bottom: 20, right: 62)),
        Phone(name: "6.7", size: CGSize(width: 932, height: 430), insets: UIEdgeInsets(top: 0, left: 59, bottom: 20, right: 59)),
        Phone(name: "6.1notch", size: CGSize(width: 844, height: 390), insets: UIEdgeInsets(top: 0, left: 47, bottom: 20, right: 47)),
        Phone(name: "SE", size: CGSize(width: 667, height: 375), insets: .zero)]

    /// Lay out and check everything on every phone; logs the totals («layout sizes: N ok, M FAIL»).
    static func run(game: Game, station: String) {
        let t0 = FrameTimer.now()
        let before = LayoutCheck.results
        let title = TitleScreen(), menu = MenuScreen(), levelUp = LevelUpScreen(), hud = HUD()
        hud.setSquad(game.marines)
        // the three upgrades with the longest descriptions (the tallest cards)
        let longest = Array(UPGRADES.sorted { $0.desc.count > $1.desc.count }.prefix(3))
        LayoutCheck.quiet = true
        defer { LayoutCheck.quiet = false; LayoutCheck.context = "" }
        for ph in phones {
            let sz = ph.size, ins = ph.insets
            for (name, fx, tier) in [("fresh", MetaFixture.fresh, 0), ("returning", MetaFixture.returning, 1), ("nightmare", MetaFixture.returning, 2)] {
                LayoutCheck.context = ph.name + " " + name
                title.layout(size: sz, insets: ins, selected: .assault, soundOn: true,
                             meta: TitleScreen.Meta(profile: fx.profile, tier: tier, station: station), layoutCheck: true)
            }
            LayoutCheck.context = ph.name
            hud.layout(size: sz, insets: ins)
            hud.checkLayout()
            menu.showPause(size: sz, state: MenuScreen.PauseState(soundOn: true, volume: 0.8, quality: "auto", hapticsOn: true,
                                                                 tierName: Difficulty.tier(0).name),
                           layoutCheck: true, insets: ins)
            levelUp.show(level: 12, offer: longest, counts: [:], cls: .cryo, size: sz, insets: ins, layoutCheck: true)
            for f in ["first", "win", "loss", "chip"] {
                guard let r = DemoFixtures.report(f) else { continue }
                LayoutCheck.context = ph.name + " " + f
                menu.showEnd(size: sz, insets: ins, report: DemoFixtures.makeReport(r, cls: .assault, stats: game.stats, station: station),
                             layoutCheck: true)
            }
        }
        menu.hide()
        levelUp.hide()
        let ok = LayoutCheck.results.ok - before.ok, fail = LayoutCheck.results.fail - before.fail
        AppLog.info(String(format: "layout sizes: %d ok, %d FAIL on %d phones in %.0f ms", ok, fail, phones.count, (FrameTimer.now() - t0) * 1000))
    }
}
