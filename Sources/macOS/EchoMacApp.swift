import SwiftUI

/// A real window, not a menu-bar accessory (2026-08-20). EchoMac began as a
/// way to hear and manage Nic's clips; it's growing into the voice interface
/// to the Claude CLI — and an interface earns a window you place and size
/// yourself, a Dock icon, and a ⌘Tab entry. The unplayed state that used to
/// ride the menu-bar icon rides the Dock badge now.
/// The app still owns the delivery server (ServerController): launch ensures
/// it, quit stops it — the window's power button and ⌘Q both land in
/// applicationWillTerminate like any normal termination.
final class EchoMacDelegate: NSObject, NSApplicationDelegate {
    let server = ServerController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Icon export mode: render the real orb and leave — no server, no UI.
        if IconExporter.runIfRequested() {
            NSApp.terminate(nil)
            return
        }
        MacSettingsView.applyTheme(UserDefaults.standard.string(forKey: "appTheme") ?? "auto")
        server.log = { EchoLog.shared.add("server: \($0)") }
        server.ensureRunning()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stopIfOwned()
    }
}

@main
struct EchoMacApp: App {
    @NSApplicationDelegateAdaptor(EchoMacDelegate.self) private var delegate
    @StateObject private var client = EchoClient()

    var body: some Scene {
        // One window, freely placed and sized. Closing it leaves the app
        // running and listening (audio keeps arriving); the Dock icon brings
        // the window back.
        Window("Echo", id: "main") {
            MacWindowView(client: client)
                .onAppear { updateBadge(client.unplayedCount) }
                .onChange(of: client.unplayedCount) { _, n in updateBadge(n) }
        }
        .defaultSize(width: 380, height: 560)
        // Status moved out of the window into the app menu (cockpit rounding):
        // click "Echo" in the menu bar to read the connection/playback line.
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Text(client.menuStatus)
            }
        }

        // Settings live in the standard place now — Echo menu → Settings (⌘,).
        Settings {
            MacSettingsView(client: client)
        }
    }

    private func updateBadge(_ n: Int) {
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }
}
