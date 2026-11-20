import CoreGraphics
import Foundation
// Prints "<id> <x> <y> <w> <h>" for the largest on-screen window owned by the named app.
let owner = CommandLine.arguments.dropFirst().first ?? "PaperCompanion"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let wins = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
let best = wins.max { a, b in
    let ra = a[kCGWindowBounds as String] as? [String: CGFloat] ?? [:], rb = b[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return (ra["Width"] ?? 0) * (ra["Height"] ?? 0) < (rb["Width"] ?? 0) * (rb["Height"] ?? 0)
}
if let w = best, let id = w[kCGWindowNumber as String] as? Int, let r = w[kCGWindowBounds as String] as? [String: CGFloat] {
    print(id, Int(r["X"]!), Int(r["Y"]!), Int(r["Width"]!), Int(r["Height"]!))
} else { exit(1) }
