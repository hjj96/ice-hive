import Foundation
import IceHiveCore

// ================================================================
//  icehive-calib — the v1.1 balance runner (web harness/calib batch.mjs + agg.mjs).
//    swift run -c release icehive-calib --preset gate --jobs 3 --out calib.jsonl --summary calib.txt --gate
//    swift run -c release icehive-calib --tiers 1 --n 8 --mode auto --th '{"trickle":1.3}' --tag t13 --out t.jsonl
//    swift run -c release icehive-calib --agg a.jsonl b.jsonl        (aggregate only; web rows work too)
//  Options: --preset gate|full|stations|legacy · --tiers 0,1,2 (-1 = legacy v1.0 row) · --n runs per class and tier
//  · --classes assault,pyro,cryo,gunner · --mode auto|passive|afk|afkbeacon · --maxs s · --seed0 1000 · --station N
//  · --th JSON (web tier field names) · --tag t · --q low|med|high (gameplay bug cap) · --jobs N
//  · --out file.jsonl (appends) · --summary file.txt · --gate
//  Exit code: 0, 1 = the gate failed, 2 = bad arguments.
// ================================================================

func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(2)
}

var flags: [String: String] = [:]
var positional: [String] = []
let argv = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < argv.count {
    let a = argv[i]
    if a.hasPrefix("--") {
        let k = String(a.dropFirst(2))
        if i + 1 < argv.count && !argv[i + 1].hasPrefix("--") { flags[k] = argv[i + 1]; i += 2 } else { flags[k] = "1"; i += 1 }
    } else { positional.append(a); i += 1 }
}

// (plain C stdio: works the same on macOS, Linux and WASI)
func readFile(_ path: String) -> String? {
    guard let f = fopen(path, "r") else { return nil }
    defer { fclose(f) }
    var bytes: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = fread(&buf, 1, buf.count, f)
        if n <= 0 { break }
        bytes += buf[0..<n]
    }
    return String(decoding: bytes, as: UTF8.self)
}

func readRows(_ path: String) -> [CalibRow] {
    guard let s = readFile(path) else { fail("cannot read \(path)") }
    return s.split(separator: "\n").compactMap { CalibRow(json: String($0)) }
}

func write(_ text: String, to path: String?, append: Bool) {
    guard let p = path else { return }
    guard let f = fopen(p, append ? "a" : "w") else { fail("cannot write \(p)") }
    fputs(text, f)
    fclose(f)
}

let t0 = Date()
var rows: [CalibRow] = []
if let agg = flags["agg"] {
    for p in [agg] + positional { rows += readRows(p) }
} else {
    let (th, errs) = Calibration.parseTh(flags["th"] ?? "")
    if !errs.isEmpty { fail("--th: " + errs.joined(separator: ", ")) }
    let seed0 = UInt32(flags["seed0"] ?? "1000") ?? 1000
    let tag = flags["tag"]
    var runs: [CalibRun] = []
    if let p = flags["preset"] {
        guard let r = Calibration.preset(p, seed0: seed0, th: th, tag: tag) else { fail("unknown preset \(p) (\(Calibration.presetNames.joined(separator: "|")))") }
        runs = r
    } else {
        let tiers = (flags["tiers"] ?? "1").split(separator: ",").map { Int($0) ?? 1 }
        let classes: [MarineClass] = (flags["classes"] ?? "assault,pyro,cryo,gunner").split(separator: ",").map {
            guard let c = MarineClass(id: String($0)) else { fail("unknown class \($0)") }
            return c
        }
        guard let mode = CalibMode(rawValue: flags["mode"] ?? "auto") else { fail("unknown mode \(flags["mode"] ?? "")") }
        let n = Int(flags["n"] ?? "1") ?? 1
        let maxs = flags["maxs"].flatMap { Float($0) }
        let station = UInt32(flags["station"] ?? "0") ?? 0
        guard let q = QualityTier(rawValue: flags["q"] ?? "med") else { fail("unknown quality \(flags["q"] ?? "") (low|med|high)") }
        for t in tiers {
            runs += Calibration.batch(tier: t, mode: mode, n: n, classes: classes, seed0: seed0, tag: tag, th: t >= 0 ? th : [:], maxs: maxs,
                                      station: station, quality: q)
        }
    }
    let jobs = Int(flags["jobs"] ?? "3") ?? 3
    let total = runs.count
    FileHandle.standardError.write("icehive-calib: \(total) runs, \(jobs) jobs\n".data(using: .utf8)!)
    rows = Calibration.runAll(runs, jobs: jobs) { done, r in
        if done % 10 == 0 || done == total {
            let s = String(format: "[%d/%d] %.0f s  last: %@ %@ %@ t=%.0f", done, total, Date().timeIntervalSince(t0), r.tag, r.cls, r.result, Double(r.t))
            FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
        }
    }
    write(rows.map { $0.json }.joined(separator: "\n") + "\n", to: flags["out"], append: true)
}

var summary = Calibration.aggregate(rows)
let (passed, gateText) = Calibration.gateText(rows)
if flags["gate"] != nil || flags["preset"] == "gate" { summary += "\n\n" + gateText }
summary += String(format: "\n\n%d rows in %.1f s\n", rows.count, Date().timeIntervalSince(t0))
print(summary)
write(summary, to: flags["summary"], append: false)
if flags["gate"] != nil && !passed { exit(1) }
