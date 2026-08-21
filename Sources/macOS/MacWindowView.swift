import SwiftUI

/// The main window since the cockpit rounding (2026-08-21): three elements,
/// top to bottom — the stories rail, one combined transport/mode row, and the
/// message pager filling everything below. The old status row is gone: status
/// and Settings live in the app menu (EchoMacApp.commands / Settings scene),
/// quitting the app is the off switch, and mute replaced "Stop listening".
/// The height saved is reserved for user input, coming later.
struct MacWindowView: View {
    @ObservedObject var client: EchoClient
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 10) {
            LaneRailView(client: client)

            // Lane utils: the open lane's curated links (dev server, canvas…).
            if let lane = client.openLane,
               let links = client.laneStates[lane]?.links, !links.isEmpty {
                LaneLinksRow(links: links)
            }

            TransportBar(client: client)

            Divider()

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
        .padding(12)
        .frame(minWidth: 340, minHeight: 420)
        // A deeper dark (Ranny): near-black ground so the orbs burn against
        // the contrast; light mode keeps the system window color.
        .background((scheme == .dark ? Color(white: 0.055)
                                     : Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea())
    }

    /// The open lane's history (all of it when no lane is open yet).
    private var visibleClips: [Clip] {
        guard let lane = client.openLane else { return client.clips }
        return client.clips.filter { $0.lane == lane }
    }
}
