import AppKit
import Foundation

/// AppleScript volume dip for Spotify and Apple Music — the fallback duck for
/// when the process tap's system-audio permission is denied (design §3a).
/// Only touches players that are already running (telling a dead app by name
/// would LAUNCH it), remembers each player's volume, restores it on release.
///
/// NSAppleScript is main-thread-bound, so all work is fired async onto main;
/// the dip lands a few ms after the clip starts — acceptable for a fallback.
/// First use fires the one-time "Echo wants to control Spotify" TCC prompt.
final class ScriptDucker {
    private struct Target { let name: String; let bundleID: String }
    private static let targets = [
        Target(name: "Spotify", bundleID: "com.spotify.client"),
        Target(name: "Music", bundleID: "com.apple.Music"),
    ]
    // Main-thread-confined.
    private var saved: [(name: String, volume: Int)] = []

    func duck(to fraction: Double) {
        DispatchQueue.main.async {
            self.saved = []
            for t in Self.targets where Self.isRunning(t.bundleID) {
                guard let v = Self.run("tell application \"\(t.name)\" to get sound volume")?
                    .int32Value else { continue }
                self.saved.append((t.name, Int(v)))
                Self.run("tell application \"\(t.name)\" to set sound volume to \(Int(Double(v) * fraction))")
            }
        }
    }

    func restore() {
        DispatchQueue.main.async {
            for (name, volume) in self.saved {
                Self.run("tell application \"\(name)\" to set sound volume to \(volume)")
            }
            self.saved = []
        }
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @discardableResult
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? result : nil
    }
}
