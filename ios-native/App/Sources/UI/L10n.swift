import Foundation
import IceHiveCore

// ================================================================
//  L10N — every player-facing string goes through the string catalog
//  App/Resources/Localizable.xcstrings (source language en; compiled
//  into en.lproj/Localizable.strings + .stringsdict for the plural
//  variants). The core hands over typed text (GameText = TextID +
//  arguments, NameRef for names); the app's own words are `UIText`
//  keys. Numbers are formatted here with an explicit English locale
//  (6,228 · ×0.8 · 38 m · 4:42), never the device region, and
//  uppercasing uses the same locale. A key the catalog lacks logs
//  «l10n missing <key>» once (CI fails on that line) and shows the key.
//  `-pseudoLoc 1.35`: every resolved piece is accented, padded to
//  ~135 % and bracketed, so the layout checks see longer languages and
//  concatenations show their seams.
// ================================================================

/// The app's own catalog keys (the core's are `TextID` / `NameRef`). `signature` as in TextID ("d" = %lld, "@" = string);
/// ci/check_strings.py reads the cases and the signature switch of this file.
enum UIText: String, CaseIterable {
    // ---- HUD
    case hudKills = "hud.kills"
    case hudTime = "hud.time"
    case hudObjective = "hud.objective"
    case hudArmor = "hud.armor"
    case hudLevel = "hud.level"
    case hudDistance = "hud.distance"
    case hudCombo = "hud.combo"
    case hudDash = "hud.dash"
    case hudMove = "hud.move"
    case hudFire = "hud.fire"
    case hudControlHint = "hud.hint.controls"
    // ---- loading cover, Metal failure
    case loadTitle = "load.title"
    case loadSub = "load.sub"
    case loadFail = "load.fail"
    case loadFailHint = "load.fail_hint"
    case appMetalFailure = "app.metal_failure"
    // ---- title
    case titleOperation = "title.operation"
    case titleStation = "title.station"
    case titleLogo1 = "title.logo.1"
    case titleLogo2 = "title.logo.2"
    case titlePremise = "title.premise"
    case titleChooseClass = "title.choose_class"
    case titleDifficulty = "title.difficulty"
    case titleGo = "title.go"
    case titleControls = "title.controls"
    // ---- pause and settings
    case pauseTitle = "pause.title"
    case pauseResume = "pause.resume"
    case pauseTutorial = "pause.tutorial"
    case pauseQuit = "pause.quit"
    case pauseControls = "pause.controls"
    case menuSound = "menu.sound"
    case menuOn = "menu.on"
    case menuOff = "menu.off"
    case menuVolume = "menu.volume"
    case menuGraphics = "menu.graphics"
    case menuGraphicsAuto = "menu.graphics_auto"
    case menuBrightness = "menu.brightness"
    case menuBrightnessNormal = "menu.brightness.normal"
    case menuBrightnessHigh = "menu.brightness.high"
    case menuBrightnessMax = "menu.brightness.max"
    case menuHaptics = "menu.haptics"
    // ---- level-up cards
    case levelupTitle = "levelup.title"
    case levelupSub = "levelup.sub"
    case levelupClass = "levelup.class"
    case levelupGear = "levelup.gear"
    case levelupTaken = "levelup.taken"
    case levelupNew = "levelup.new"

    var signature: String {
        switch self {
        case .hudLevel, .hudDistance, .hudCombo, .menuVolume, .levelupTaken: return "d"
        case .titleStation, .menuSound, .menuGraphics, .menuGraphicsAuto, .menuBrightness, .menuHaptics, .levelupClass: return "@"
        default: return ""
        }
    }
}

/// An argument of an app key: a count (%lld) or an already resolved string (%@).
enum UIArg {
    case int(Int)
    case str(String)
}

enum L10n {
    /// English number formatting whatever the device region says.
    static let locale = Locale(identifier: "en")
    /// `-pseudoLoc <factor>` (0 = off): accents, padding to `factor` × the length, brackets.
    static var pseudo: Double = LaunchOptions.current.pseudoLoc ?? 0
    /// The twelve sector letters of generated stations (not pseudo-localised: it is a lookup table).
    static let sectorLettersKey = "name.sector.letters"

    private static var formats: [String: String] = [:]
    private static var missing = Set<String>()
    private static let sentinel = "\u{1}l10n\u{1}"
    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f
    }()

    // ---------------------------------------------------------------- public API
    /// A core line.
    static func string(_ t: GameText) -> String {
        render(t.id.rawValue, t.args.map { a -> UIArg in
            switch a {
            case .int(let v): return .int(v)
            case .num(let v): return .str(num(v))
            case .tenths(let v): return .str(tenths(v))
            case .clock(let v): return .str(clock(v))
            case .name(let n): return .str(name(n))
            case .text(let x): return .str(string(x))
            }
        })
    }

    /// A name.
    static func name(_ r: NameRef) -> String {
        if case .sector(let letter, let number) = r {
            let letters = Array(format(sectorLettersKey))
            let l = letters.isEmpty ? "?" : String(letters[max(0, letter) % letters.count])
            return render(r.key, [.str(l), .int(number)])
        }
        return render(r.key, [])
    }

    /// An app key.
    static func ui(_ k: UIText, _ args: UIArg...) -> String { render(k.rawValue, args) }

    /// Uppercase with the explicit locale (labels, banners, the objective line).
    static func upper(_ s: String) -> String { s.uppercased(with: locale) }

    /// 6,228.
    static func num(_ v: Int) -> String { grouping.string(from: NSNumber(value: v)) ?? "\(v)" }
    /// 0.8 / 1.5 (tenths, one decimal, a point).
    static func tenths(_ t: Int) -> String {
        let a = abs(t)
        return (t < 0 ? "-" : "") + "\(a / 10).\(a % 10)"
    }
    /// m:ss.
    static func clock(_ s: Int) -> String {
        let v = max(0, s), sec = v % 60
        return "\(v / 60):" + (sec < 10 ? "0\(sec)" : "\(sec)")
    }

    /// Characters a glyph-atlas label needs to show `samples` (plus every digit): the atlas charset follows the catalog.
    static func charset(_ samples: [String]) -> String {
        var s = Set<Character>("0123456789")
        for x in samples { for c in x where c != " " && c != "\n" { s.insert(c) } }
        return String(s.sorted())
    }

    /// Bold / plain runs of a catalog value marked with `**bold**` (control hints).
    static func runs(_ s: String) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        for (k, part) in s.components(separatedBy: "**").enumerated() where !part.isEmpty { out.append((part, k % 2 == 1)) }
        return out
    }

    // ---------------------------------------------------------------- lookup and formatting
    /// The catalog's value for `key` (the plural-aware format object for plural keys), cached.
    static func format(_ key: String) -> String {
        if let f = formats[key] { return f }
        var s = Bundle.main.localizedString(forKey: key, value: sentinel, table: nil)
        if s == sentinel || s.isEmpty {
            if missing.insert(key).inserted { AppLog.error("l10n missing \(key)") }
            s = key
        }
        formats[key] = s
        return s
    }

    /// Format `key` with `args` (positional %n$lld / %n$@ in the catalog). With pseudo-localisation on, string
    /// arguments go in as private-use markers, the formatted line is transformed, then the (already transformed)
    /// arguments replace their markers: every piece is pseudo-localised exactly once.
    private static func render(_ key: String, _ args: [UIArg]) -> String {
        let f = format(key)
        let pseudoOn = pseudo > 0 && key != sectorLettersKey
        if args.isEmpty {
            // a plain value is not a format: no %% unescaping needed unless it has arguments
            return pseudoOn ? Pseudo.transform(f, factor: pseudo) : f
        }
        var cargs: [CVarArg] = []
        var strs: [String] = []
        for a in args {
            switch a {
            case .int(let v): cargs.append(Int64(v))
            case .str(let s):
                if pseudoOn {
                    cargs.append(String(UnicodeScalar(0xE000 + strs.count)!))
                    strs.append(s)
                } else {
                    cargs.append(s)
                }
            }
        }
        var out = String(format: f, locale: locale, arguments: cargs)
        if out.contains("%#@") || out.contains("(null)") {
            // the plural rules did not apply (no .stringsdict entry for a %#@ format): as bad as a missing key
            if missing.insert(key + "#plural").inserted { AppLog.error("l10n missing plural rule for \(key): «\(out)»") }
        }
        if pseudoOn {
            out = Pseudo.transform(out, factor: pseudo)
            for (k, s) in strs.enumerated() { out = out.replacingOccurrences(of: String(UnicodeScalar(0xE000 + k)!), with: s) }
        }
        return out
    }

    /// Every key resolved once (CI: `-demo layout` logs the count; anything missing has logged «l10n missing»), and the
    /// plural rules checked on a count of 1 and of 100.
    @discardableResult
    static func audit() -> Int {
        var n = 0
        for id in TextID.allCases { _ = format(id.rawValue); n += 1 }
        for r in NameRef.all { _ = name(r); n += 1 }
        for k in UIText.allCases { _ = format(k.rawValue); n += 1 }
        _ = format(sectorLettersKey)
        let one = string(GameText(.bannerHoldSub, [.int(1)])), many = string(GameText(.bannerHoldSub, [.int(100)]))
        if pseudo == 0 && one.replacingOccurrences(of: "1", with: "100") == many && missing.insert("#plural").inserted {
            // «1 second» and «100 seconds» came out the same: the .stringsdict plural rules were not applied
            AppLog.error("l10n missing plural rules: «\(one)» / «\(many)»")
        }
        let letters = format(sectorLettersKey)
        AppLog.info("l10n audit: \(n) keys, \(missing.count) missing, plural «\(one)» / «\(many)», sector letters \(letters.count), pseudo \(pseudo)")
        return missing.count
    }
}

/// Pseudo-localisation of a resolved string: Latin letters get accents the bundled fonts carry (Latin-1 and
/// Latin Extended-A only), the text is padded with «~» to `factor` × its length — spread over the words in
/// proportion to their length, so a line split at « — » / « · » grows on both sides as a longer language would —
/// and bracketed. Digits, separators and private-use markers are left alone.
enum Pseudo {
    private static let map: [Character: Character] = {
        let from = Array("aceinouyAEINOUYCdghjklrstwzDGHJKLRSTWZ")
        let to = Array("åçéîñöüýÅÉÎÑÖÜÝÇďĝĥĵķļŕšţŵžĎĜĤĴĶĻŔŠŢŴŽ")
        var m: [Character: Character] = [:]
        for (a, b) in zip(from, to) { m[a] = b }
        return m
    }()

    static func transform(_ s: String, factor: Double) -> String {
        if s.isEmpty { return s }
        let chars = Array(s)
        let n = chars.count
        let pad = max(0, Int((Double(n) * factor).rounded(.up)) - n - 2)
        let letters = chars.filter { $0.isLetter }.count
        var out = "["
        var seen = 0, added = 0
        for (i, c) in chars.enumerated() {
            out.append(map[c] ?? c)
            if c.isLetter {
                seen += 1
                let wordEnd = i + 1 == n || !chars[i + 1].isLetter
                if wordEnd && letters > 0 {
                    let want = Int((Double(pad) * Double(seen) / Double(letters)).rounded())
                    if want > added { out += String(repeating: "~", count: want - added); added = want }
                }
            }
        }
        if added < pad { out += String(repeating: "~", count: pad - added) }
        return out + "]"
    }
}

/// Symbols Oswald does not carry, drawn in JetBrains Mono (bundled) instead of falling back to the system font.
enum Glyphs {
    /// ◆ (medal line, title ability line).
    static let diamond = "\u{25C6}"
    /// ▸ (the report's next-goal pointer).
    static let pointer = "\u{25B8}"
}
