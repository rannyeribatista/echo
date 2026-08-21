import SwiftUI

struct ContentView: View {
    @StateObject private var client = EchoClient()
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("walkieMode") private var walkieMode = true
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // The stories rail (cockpit sit) — same shared view as the Mac.
                LaneRailView(client: client)
                    .padding(.horizontal)

                statusCard

                Button(client.isListening ? "Stop listening" : "Start listening") {
                    client.toggleListening()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // The transport rides fixed on top; the transcript below is
                // the whole content area — the open lane's messages,
                // chat-style, current one at the bottom (cockpit drive).
                TransportBar(client: client)
                    .padding(.horizontal)

                if visibleClips.isEmpty {
                    Spacer()
                    Text(client.openLane == nil || client.clips.isEmpty
                         ? "No messages in the last 24 hours."
                         : "No messages from this lane in the last 24 hours.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    TranscriptView(client: client, clips: visibleClips)
                        .padding(.horizontal)
                }
            }
            .padding(.top)
            .navigationTitle("Echo")
            .toolbar {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            // Foreground watchdog: if iOS suspended the poll loop while
            // backgrounded, restart it instead of showing a dead "listening".
            .onChange(of: scenePhase) { phase in
                if phase == .active { client.appBecameActive() }
            }
        }
    }

    /// The open lane's history (all of it when no lane is open yet).
    private var visibleClips: [Clip] {
        guard let lane = client.openLane else { return client.clips }
        return client.clips.filter { $0.lane == lane }
    }

    private var statusCard: some View {
        VStack(spacing: 6) {
            Text(stateEmoji).font(.system(size: 44))
            Text(client.statusText)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }

    /// Green only when the connection is genuinely healthy — yellow/red mean
    /// what the label under them says.
    private var stateEmoji: String {
        guard client.isListening else { return "⚪️" }
        switch client.state {
        case .degraded: return "🟡"
        case .error: return "🔴"
        default: return "🟢"
        }
    }
}

// ClipRow / LaneChip / PulsingDot / ActiveMessageCard live in
// Sources/Shared/ClipViews.swift — the menu-bar panel renders the same rows.
