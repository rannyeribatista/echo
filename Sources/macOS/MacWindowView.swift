import SwiftUI

/// The main window (a menu-bar panel until 2026-08-20) — the iPhone main
/// screen on the desktop: status line, listening + auto-play + walkie
/// controls, the 24h history (same shared rows), and the shared walkie card /
/// mini-player while a message plays. Freely resizable; the frame below is
/// just the floor.
struct MacWindowView: View {
    @ObservedObject var client: EchoClient
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("walkieMode") private var walkieMode = true
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 10) {
            // The stories rail — the window's first element (cockpit sit):
            // one circle per open lane; tap = that lane's pane fills the
            // window below and becomes the lane that sounds.
            LaneRailView(client: client)

            HStack(spacing: 8) {
                Circle().fill(stateColor).frame(width: 9, height: 9)
                Text(client.statusText)
                    .font(.footnote).foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings")
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.plain)
                .help("Quit Echo")
            }

            HStack {
                Button(client.isListening ? "Stop listening" : "Start listening") {
                    client.toggleListening()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Spacer()
                Toggle("Auto-play", isOn: $autoPlay)
                    .toggleStyle(.checkbox)
                    .font(.footnote)
                    .help("Play each message the moment it arrives, ducking whatever else is audible.")
                Toggle("Walkie", isOn: $walkieMode)
                    .toggleStyle(.checkbox)
                    .font(.footnote)
                    .help("Pause at each part of a message — Continue plays the next; “Over” marks the end. Off = play straight through.")
            }

            Divider()

            // The active message rides on top — full text, controls always
            // there; the history scrolls beneath it, its open row bordered.
            if let open = client.openClip {
                ActiveMessageCard(client: client, clip: open)
            }

            if visibleClips.isEmpty {
                Spacer()
                Text(client.openLane == nil || client.clips.isEmpty
                     ? "No messages in the last 24 hours."
                     : "No messages from this lane in the last 24 hours.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleClips) { clip in
                            ClipRow(clip: clip, isOpen: clip.id == client.openClip?.id) {
                                client.play(clip)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 340, minHeight: 420)
        .sheet(isPresented: $showSettings) { MacSettingsView(client: client) }
    }

    /// The open lane's history (all of it when no lane is open yet).
    private var visibleClips: [Clip] {
        guard let lane = client.openLane else { return client.clips }
        return client.clips.filter { $0.lane == lane }
    }

    /// Same truth-telling as the iPhone's emoji: green only when the
    /// connection is genuinely healthy.
    private var stateColor: Color {
        guard client.isListening else { return .gray }
        switch client.state {
        case .degraded: return .yellow
        case .error: return .red
        default: return .green
        }
    }
}
