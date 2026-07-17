import SwiftUI

struct ContentView: View {
    @StateObject private var client = EchoClient()
    @AppStorage("autoPlay") private var autoPlay = true
    @State private var showSettings = false

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
        }
    }

    private var statusCard: some View {
        VStack(spacing: 6) {
            Text(client.isListening ? "🟢" : "⚪️").font(.system(size: 44))
            Text(client.status).foregroundStyle(.secondary)
        }
    }
}
