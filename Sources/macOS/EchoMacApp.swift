import SwiftUI

/// Menu-bar entry point (design §2): a persistent top-bar icon; click it and
/// a small window-style panel drops down with the same clip list the iPhone
/// shows. `LSUIElement` in project.yml keeps Echo out of the Dock and ⌘Tab —
/// always visible up top, never in the way.
/// The app owns the delivery server (ServerController): launch ensures it,
/// quit stops it — quit via the panel's power button lands in
/// applicationWillTerminate like any normal termination.
final class EchoMacDelegate: NSObject, NSApplicationDelegate {
    let server = ServerController()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        MenuBarExtra {
            MacPanelView(client: client)
        } label: {
            // The unplayed state rides the icon itself: plain waveform when
            // clear, filled variant while something waits.
            Image(systemName: client.unplayedCount > 0 ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}
