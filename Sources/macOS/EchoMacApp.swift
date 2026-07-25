import SwiftUI

/// Menu-bar entry point (design §2): a persistent top-bar icon; click it and
/// a small window-style panel drops down with the same clip list the iPhone
/// shows. `LSUIElement` in project.yml keeps Echo out of the Dock and ⌘Tab —
/// always visible up top, never in the way.
@main
struct EchoMacApp: App {
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
