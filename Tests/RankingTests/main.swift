import Foundation
import CoreGraphics

// Ranking checks against the real installed apps plus a few synthetic look-alikes.
// Run with: ./build.sh test

var failures = 0
func expect(_ cond: Bool, _ msg: String) {
    print(cond ? "  ok   \(msg)" : "  FAIL \(msg)")
    if !cond { failures += 1 }
}

let scanStart = Date()
var apps = AppIndex.scan()
print("Indexed \(apps.count) apps in \(Int(Date().timeIntervalSince(scanStart) * 1000)) ms")

// Look-alikes so the Blender/Bartender case is testable even if they aren't installed.
for name in ["Bartender 5", "Visual Studio Code", "Blackmagic Disk Speed Test", "Brave Browser"] {
    apps.append(AppEntry(url: URL(fileURLWithPath: "/Applications/\(name).app"), name: name, id: "test.\(name)"))
}

let usageURL = FileManager.default.temporaryDirectory.appendingPathComponent("glasslight-test-\(getpid()).json")
let usage = Usage(url: usageURL)
func top(_ q: String) -> String { Ranker.search(q, in: apps, usage: usage, limit: 6).first?.name ?? "<none>" }
func names(_ q: String) -> [String] { Ranker.search(q, in: apps, usage: usage, limit: 6).map(\.name) }

print("\nSpelling, case and typos")
let cases: [(String, String)] = [
    ("safari", "Safari"), ("SAFARI", "Safari"), ("sAfArI", "Safari"), ("safri", "Safari"), ("sfari", "Safari"),
    ("blender", "Blender"), ("blendr", "Blender"), ("blnder", "Blender"), ("bledner", "Blender"), ("BLENDER", "Blender"),
    ("photoshop", "Adobe Photoshop 2026"), ("photshop", "Adobe Photoshop 2026"), ("fotoshop", "Adobe Photoshop 2026"),
    ("whatsap", "WhatsApp"), ("whtsapp", "WhatsApp"), ("watsapp", "WhatsApp"),
    ("system settings", "System Settings"), ("systm setings", "System Settings"), ("settings", "System Settings"),
    ("terminl", "Terminal"), ("termnial", "Terminal"),
    ("activity", "Activity Monitor"), ("actmon", "Activity Monitor"),
    ("vsc", "Visual Studio Code"), ("code", "Visual Studio Code"),
    ("calcualtor", "Calculator"), ("finder", "Finder"), ("powerpoint", "Microsoft PowerPoint"),
    ("powerpiont", "Microsoft PowerPoint"), ("excel", "Microsoft Excel"), ("exel", "Microsoft Excel"),
    ("creative cloud", "Adobe Creative Cloud"),
]
for (q, want) in cases { expect(top(q) == want, "\"\(q)\" -> \(top(q))\(top(q) == want ? "" : "  (wanted \(want))")") }

print("\nLearning: B-apps before any history: \(names("b"))")
for _ in 0..<3 { usage.record(query: Ranker.normalize("ble"), id: apps.first { $0.name == "Blender" }!.id) }
usage.record(query: Ranker.normalize("bar"), id: "test.Bartender 5")
print("After opening Blender 3x (via \"ble\") and Bartender once: \(names("b"))")
expect(top("b") == "Blender", "\"b\" -> \(top("b"))")
expect(top("B") == "Blender", "\"B\" -> \(top("B"))")
expect(top("bl") == "Blender", "\"bl\" -> \(top("bl"))")
expect(top("ba") == "Bartender 5", "\"ba\" still -> \(top("ba"))")
expect(top("blackmagic") == "Blackmagic Disk Speed Test", "exact name still wins over history: \(top("blackmagic"))")

// Learning a misspelling: user keeps picking Brave for "brw".
let brave = apps.first { $0.name == "Brave Browser" }!
print("\nBefore learning \"brw\": \(names("brw"))")
usage.record(query: Ranker.normalize("brw"), id: brave.id)
expect(top("brw") == "Brave Browser", "\"brw\" -> \(top("brw")) after one pick")

print("\nSpeed")
let queries = ["b", "bl", "ble", "blendr", "photshop", "sys set", "xq", "microsoft word", "vsc", "termnial"]
let t0 = Date()
let rounds = 2000
for _ in 0..<rounds { for q in queries { _ = Ranker.search(q, in: apps, usage: usage, limit: 6) } }
let perQuery = Date().timeIntervalSince(t0) / Double(rounds * queries.count) * 1_000_000
print(String(format: "  %.1f µs per keystroke search over %d apps", perQuery, apps.count))
expect(perQuery < 2000, "search under 2 ms")

print("\nShortcut: double-tap right ⌘")
enum Ev { case down(Double), up(Double), key(Double), leftCmd(Double), downWithShift(Double) }
func fires(_ events: [Ev]) -> Int {
    var d = DoubleTapDetector()
    // Flag values as macOS 27 actually delivers them (captured from a live tap).
    let rightDown = CGEventFlags(rawValue: 0x20100110)
    let leftDown = CGEventFlags(rawValue: 0x20100108)
    let none = CGEventFlags(rawValue: 0x20000100)
    var lastKeyOrClick = -100.0 // only observable as "seconds since", like CGEventSource provides
    var count = 0
    for e in events {
        var hit = false
        func feed(_ code: Int64, _ flags: CGEventFlags, _ t: Double) {
            hit = d.handle(keyCode: code, flags: flags, at: t, otherInputAge: { t - lastKeyOrClick })
        }
        switch e {
        case .down(let t): feed(0x36, rightDown, t)
        case .up(let t): feed(0x36, none, t)
        case .key(let t): lastKeyOrClick = t
        case .leftCmd(let t): feed(0x37, leftDown, t)
        case .downWithShift(let t): feed(0x36, rightDown.union(.maskShift), t)
        }
        if hit { count += 1 }
    }
    return count
}
expect(fires([.key(-0.05), .down(0), .up(0.08), .down(0.2), .up(0.27)]) == 1, "typing right before the taps is fine")
expect(fires([.down(0), .up(0.08), .key(0.12), .down(0.2), .up(0.27)]) == 0, "a key between the taps cancels")
expect(fires([.down(0), .up(0.08), .down(0.2), .up(0.27)]) == 1, "quick double tap opens")
expect(fires([.down(0), .up(0.08), .down(0.6), .up(0.68)]) == 0, "two slow taps don't")
expect(fires([.down(0), .up(0.08), .down(0.6), .up(0.68), .down(0.8), .up(0.86)]) == 1, "...but a quick tap after them does")
expect(fires([.down(0), .up(0.6), .down(0.7), .up(0.76)]) == 0, "holding ⌘ isn't a tap")
expect(fires([.down(0), .up(0.08), .down(0.2), .key(0.25), .up(0.3)]) == 0, "tap then ⌘C doesn't open")
expect(fires([.down(0), .key(0.05), .up(0.1), .down(0.2), .up(0.26)]) == 0, "⌘C then tap doesn't open")
expect(fires([.leftCmd(0), .leftCmd(0.08), .leftCmd(0.2), .leftCmd(0.27)]) == 0, "left ⌘ is ignored")
expect(fires([.downWithShift(0), .up(0.08), .downWithShift(0.2), .up(0.27)]) == 0, "⇧ held: no")
expect(fires([.down(0), .up(0.08), .down(0.2), .up(0.27), .down(0.4), .up(0.46)]) == 1, "triple tap opens once")
expect(fires([.down(0), .up(0.08), .down(0.2), .up(0.27), .down(0.4), .up(0.46), .down(0.6), .up(0.66)]) == 2, "two double taps toggle twice")

try? FileManager.default.removeItem(at: usageURL)
print(failures == 0 ? "\nAll passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
