import SwiftUI

/// The row/transport views both platforms render — the part of the UI the
/// design doc calls out as the thing that must never fork (iPhone list and
/// menu-bar panel show the same rows).

/// One history row: pulsing dot while unplayed, dimmed once played.
struct ClipRow: View {
    let clip: Clip
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: 12) {
                if clip.playedAt == nil { PulsingDot() }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if !clip.lane.isEmpty { LaneChip(lane: clip.lane) }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(clip.playedAt == nil ? 1 : 0.45)
    }
}

/// The lane tag capsule — shared by the history rows and the mini-player.
struct LaneChip: View {
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

struct PulsingDot: View {
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

/// Bottom bar while a clip is loaded: label, pause/resume, back-to-start and a
/// scrubber. Progress arrives via EchoClient.playbackTime (~4×/s); while the
/// finger is on the slider the bar shows the drag position instead, and the
/// seek fires on release.
struct MiniPlayerBar: View {
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
