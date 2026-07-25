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
                                ClipRow(clip: clip) { client.play(clip) }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .padding(.top)
            // Mini-player: the one control surface once a clip is playing —
            // pause/resume, back-to-start, scrub. Before this, playback was
            // fire-and-forget.
            .safeAreaInset(edge: .bottom) {
                if let clip = client.nowPlayingClip {
                    MiniPlayerBar(client: client, clip: clip)
                }
            }
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

/// One history row: pulsing dot while unplayed, dimmed once played.
private struct ClipRow: View {
    let clip: Clip
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                if clip.playedAt == nil { PulsingDot() }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if !clip.lane.isEmpty { laneChip }
                        Text(clip.displayedAt, style: .time)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(clip.label).lineLimit(1)
                }
                Spacer()
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
        }
        .buttonStyle(.plain)
        .opacity(clip.playedAt == nil ? 1 : 0.45)
    }

    private var laneChip: some View { LaneChip(lane: clip.lane) }
}

/// The lane tag capsule — shared by the history rows and the mini-player.
private struct LaneChip: View {
    let lane: String

    var body: some View {
        Text(lane)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(.tint)
    }
}

/// Bottom bar while a clip is loaded: label, pause/resume, back-to-start and a
/// scrubber. Progress arrives via EchoClient.playbackTime (~4×/s); while the
/// finger is on the slider the bar shows the drag position instead, and the
/// seek fires on release.
private struct MiniPlayerBar: View {
    @ObservedObject var client: EchoClient
    let clip: Clip
    @State private var scrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                if !clip.lane.isEmpty { LaneChip(lane: clip.lane) }
                Text(clip.label)
                    .font(.footnote)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(timeText(shownTime)) / \(timeText(client.playbackDuration))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Button { client.restartClip() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                Button { client.togglePause() } label: {
                    Image(systemName: client.isPaused ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .frame(width: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                Slider(
                    value: Binding(
                        get: { scrubbing ? scrubTime
                                         : min(client.playbackTime, client.playbackDuration) },
                        set: { scrubTime = $0 }
                    ),
                    in: 0...max(client.playbackDuration, 0.01),
                    onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing { client.scrub(to: scrubTime) }
                    }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private var shownTime: TimeInterval { scrubbing ? scrubTime : client.playbackTime }

    private func timeText(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PulsingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 8, height: 8)
            .opacity(dim ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
