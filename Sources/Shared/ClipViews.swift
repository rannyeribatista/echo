import SwiftUI

/// The row/card views both platforms render — the part of the UI the
/// design doc calls out as the thing that must never fork (iPhone list and
/// Mac window show the same rows).
///
/// Layout since 2026-08-20: the ACTIVE message (EchoClient.openClip) lives in
/// a card pinned above the history — full text always visible, controls always
/// available (live transport while its audio plays, replay when idle). The
/// history scrolls beneath it, and the open message's row wears a border so
/// newer unplayed messages are visible relative to it.

/// One history row: pulsing dot while unplayed, dimmed once played, a border
/// when it's the message the card above is showing.
struct ClipRow: View {
    let clip: Clip
    var isOpen = false
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
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(clip.playedAt == nil ? 1 : 0.45)
        .overlay {
            if isOpen {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5)
            }
        }
    }
}

/// The lane tag capsule — shared by the history rows and the active card.
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

/// The active message: full text always showing, controls always available.
/// While its audio is live it carries the transport — pause/resume,
/// back-to-start, the walkie Continue gate, a scrubber for single-file clips —
/// and when idle it offers replay. Walkie text renders per chunk: heard parts
/// dim, the current part leads, pending parts wait in secondary.
struct ActiveMessageCard: View {
    @ObservedObject var client: EchoClient
    let clip: Clip
    @State private var scrubbing = false
    @State private var scrubTime: TimeInterval = 0

    /// This clip's audio is the one in flight (playing, gated, or rendering).
    private var isLive: Bool { client.nowPlayingClip?.id == clip.id }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if !clip.lane.isEmpty { LaneChip(lane: clip.lane) }
                Text(clip.displayedAt, style: .time)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let chunks = clip.chunks, !chunks.isEmpty {
                    Text("\(min(client.currentChunk + 1, chunks.count)) of \(chunks.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .opacity(isLive ? 1 : 0)
                }
            }
            ScrollView {
                messageText
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 170)
            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var messageText: some View {
        if let chunks = clip.chunks {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(chunks, id: \.seq) { chunk in
                    Text(chunk.text)
                        .font(.footnote)
                        .foregroundStyle(!isLive || chunk.seq == client.currentChunk
                                         ? AnyShapeStyle(.primary)
                                         : AnyShapeStyle(.secondary))
                        .opacity(isLive && chunk.seq < client.currentChunk ? 0.45 : 1)
                        .strikethrough(chunk.failed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text(clip.text).font(.footnote)
        }
    }

    @ViewBuilder private var controls: some View {
        if isLive {
            HStack(spacing: 10) {
                Button { client.restartClip() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(client.awaitingContinue || client.awaitingRender)
                Button { client.togglePause() } label: {
                    Image(systemName: client.isPaused ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .frame(width: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(client.awaitingContinue || client.awaitingRender)
                // Stop ends the message here and hands the music back — pause
                // deliberately keeps the duck engaged, so this is the way out.
                Button { client.stopPlayback() } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                if client.awaitingRender {
                    Spacer()
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Rendering…").font(.caption)
                    }
                    .foregroundStyle(.secondary)
                } else if client.awaitingContinue {
                    Spacer()
                    Button { client.continueMessage() } label: {
                        Label("Continue", systemImage: "play.circle.fill")
                            .font(.callout.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    // The reproduction bar — scoped to the playing unit: the
                    // whole clip for single-file messages, the current chunk
                    // for walkie ones. While the finger is down the bar shows
                    // the drag position; the seek fires on release.
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
                    Text("\(timeText(scrubbing ? scrubTime : client.playbackTime)) / \(timeText(client.playbackDuration))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                Button { client.play(clip) } label: {
                    Label("Play again", systemImage: "play.fill")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
        }
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
