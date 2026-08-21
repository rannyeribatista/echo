import SwiftUI

/// The main window since the cockpit rounding (2026-08-21), completed by the
/// input build the same night: the stories rail, the transport/mode row, the
/// message pager — and the PromptBar at the bottom, the height the rounding
/// cleared for it. Status and Settings live in the app menu; quitting the
/// app is the off switch.
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

            PromptBar(client: client)
        }
        .padding(12)
        .frame(minWidth: 340, minHeight: 420)
        // The dark ground (Ranny's A/B, Settings → Appearance): both start
        // near-black at the top. "Gray" settles into the previous gray at the
        // bottom; "Status tint" lets a whisper of the featured sphere's color
        // gather at the bottom margin — barely there, fading fast upward —
        // and tweens with status changes.
        .background(CockpitGround(client: client).ignoresSafeArea())
    }


    /// The open lane's history (all of it when no lane is open yet).
    private var visibleClips: [Clip] {
        guard let lane = client.openLane else { return client.clips }
        return client.clips.filter { $0.lane == lane }
    }
}
