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
                statusCard

                Toggle("Always-on (auto-play)", isOn: $autoPlay)
                    .padding(.horizontal)
                Toggle("Walkie mode (pause between parts)", isOn: $walkieMode)
                    .padding(.horizontal)
                Text(walkieMode
                     ? "A message plays its first part, then waits — Continue plays the next; “Over” marks the end."
                     : (autoPlay
                        ? "Messages duck your music and play straight through the moment they arrive."
                        : "Messages wait here until you tap play."))
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal)

                Button(client.isListening ? "Stop listening" : "Start listening") {
                    client.toggleListening()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                // The active message rides on top — full text, controls always
                // there; the history scrolls beneath it, its open row bordered.
                if let open = client.openClip {
                    ActiveMessageCard(client: client, clip: open)
                        .padding(.horizontal)
                }

                if client.clips.isEmpty {
                    Spacer()
                    Text("No messages in the last 24 hours.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    // 24h history, newest first. Tap any row to (re)play it.
                    List {
                        Section("Last 24 hours") {
                            ForEach(client.clips) { clip in
                                ClipRow(clip: clip, isOpen: clip.id == client.openClip?.id) {
                                    client.play(clip)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
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
