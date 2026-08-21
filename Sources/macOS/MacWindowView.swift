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
    @AppStorage("darkGround") private var darkGround = "status"

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
        // The dark ground (Ranny's A/B, Settings → Appearance): both start
        // near-black at the top. "Gray" settles into the previous gray at the
        // bottom; "Status tint" lets a whisper of the featured sphere's color
        // gather at the bottom margin — barely there, fading fast upward —
        // and tweens with status changes.
        .background(groundView.ignoresSafeArea())
    }

    @ViewBuilder private var groundView: some View {
        if scheme == .dark {
            if darkGround == "status" {
                LinearGradient(stops: [
                    .init(color: Color(white: 0.022), location: 0),
                    .init(color: Color(white: 0.035), location: 0.68),
                    .init(color: statusTint, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .animation(.easeInOut(duration: 0.9), value: featuredStateKey)
            } else {
                LinearGradient(colors: [Color(white: 0.022), Color(white: 0.055)],
                               startPoint: .top, endPoint: .bottom)
            }
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    /// The featured lane's status hue, whispered (mirrors the orb palette).
    private var statusTint: Color {
        let lane = client.lanes.first(where: { $0.isOpen })
        let hue: Double
        switch lane?.state {
        case "working": hue = 0.49
        case "attention": hue = 0.08
        case "ready": hue = 0.58
        default: hue = (lane?.unplayed ?? 0) > 0 ? 0.74 : 0.62
        }
        return Color(hue: hue, saturation: 0.45, brightness: 0.14)
    }

    private var featuredStateKey: String {
        let lane = client.lanes.first(where: { $0.isOpen })
        return "\(lane?.state ?? "-")|\((lane?.unplayed ?? 0) > 0)"
    }

    /// The open lane's history (all of it when no lane is open yet).
    private var visibleClips: [Clip] {
        guard let lane = client.openLane else { return client.clips }
        return client.clips.filter { $0.lane == lane }
    }
}
