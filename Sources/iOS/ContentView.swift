import SwiftUI

/// The iPhone window since the phone pass (2026-08-21 night): pure cockpit —
/// orbs, links, transport, pager, and nothing else. Status card, listen
/// toggle, the big title, and the in-app settings gear are all gone; the app
/// comes up listening (opening it IS the intent), and every preference lives
/// in the system Settings app (Settings.bundle mirrors the Mac's panel:
/// connection, appearance incl. the dark ground, reading typography). The
/// ground is the shared CockpitGround — same near-black-to-status-whisper
/// gradient as the Mac.
struct ContentView: View {
    @StateObject private var client = EchoClient()
    @AppStorage("appTheme") private var appTheme = "auto"
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 14) {
            LaneRailView(client: client)

            if let lane = client.openLane,
               let links = client.laneStates[lane]?.links, !links.isEmpty {
                LaneLinksRow(links: links)
            }

            TransportBar(client: client)

            if visibleClips.isEmpty {
                Spacer()
                Text(client.openLane == nil || client.clips.isEmpty
                     ? "No messages in the last 24 hours."
                     : "No messages from this lane in the last 24 hours.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            } else {
                TranscriptView(client: client, clips: visibleClips)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        // The input rides in the bottom SAFE-AREA INSET rather than as the
        // last row of the stack (Ranny: it sat partly under the keyboard).
        // This is the Messages idiom: the system keeps an inset view above
        // the keyboard when it opens and above the home indicator when it
        // doesn't, and the pager above gets inset by exactly its height
        // instead of being overlapped.
        .safeAreaInset(edge: .bottom, spacing: 8) {
            PromptBar(client: client)
                .padding(.horizontal)
                .padding(.bottom, 4)
        }
        .background(CockpitGround(client: client).ignoresSafeArea())
        .preferredColorScheme(appTheme == "auto" ? nil
                              : (appTheme == "dark" ? .dark : .light))
        // Foreground watchdog: if iOS suspended the poll loop while
        // backgrounded, restart it instead of showing a dead "listening".
        .onChange(of: scenePhase) { phase in
            if phase == .active { client.appBecameActive() }
        }
    }

    /// The open lane's history (all of it when no lane is open yet).
    private var visibleClips: [Clip] {
        guard let lane = client.openLane else { return client.clips }
        return client.clips.filter { $0.lane == lane }
    }
}
