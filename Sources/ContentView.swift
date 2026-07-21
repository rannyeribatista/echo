import SwiftUI

struct ContentView: View {
    @StateObject private var client = EchoClient()
    @AppStorage("autoPlay") private var autoPlay = true
    @State private var showSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                statusCard

                Toggle("Always-on (auto-play)", isOn: $autoPlay)
                    .padding(.horizontal)
                Text(autoPlay
                     ? "Messages duck your music and play the moment they arrive."
                     : "Messages wait here until you tap play.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal)

                Button(client.isListening ? "Stop listening" : "Start listening") {
                    client.toggleListening()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if client.pending.isEmpty {
                    Spacer()
                } else {
                    List(client.pending) { clip in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(clip.text).lineLimit(2)
                                Text(clip.receivedAt, style: .time)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                client.play(clip)
                            } label: {
                                Image(systemName: "play.circle.fill").font(.title2)
                            }
                            .buttonStyle(.plain)
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
