import SwiftUI

/// The panel that drops from the menu-bar icon — the iPhone main screen
/// distilled into a small box: status line, listening + auto-play controls,
/// the 24h history (same shared rows), and the shared mini-player while a
/// clip plays.
struct MacPanelView: View {
    @ObservedObject var client: EchoClient
    @AppStorage("autoPlay") private var autoPlay = true
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 10) {
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
            }

            Divider()

            if client.clips.isEmpty {
                Spacer()
                Text("No messages in the last 24 hours.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(client.clips) { clip in
                            ClipRow(clip: clip) { client.play(clip) }
                                .padding(.vertical, 4)
                        }
                    }
                }
            }

            if let clip = client.nowPlayingClip {
                MiniPlayerBar(client: client, clip: clip)
            }
        }
        .padding(12)
        .frame(width: 340, height: 440)
        .sheet(isPresented: $showSettings) { MacSettingsView(client: client) }
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
