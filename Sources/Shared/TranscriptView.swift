import SwiftUI

/// The transcript — the window's content area since the cockpit drive
/// (2026-08-21, Ranny's spec): the open lane's messages as one chat-style
/// scroll, oldest at the top, the current message living at the bottom.
/// Message text is large and unboxed and takes the whole window; separators
/// carry the time; scrolling snaps magnetically to message bottoms — push past
/// an edge and it pops into the bottom of the message above. The transport
/// lives in a fixed bar above (TransportBar); the text keeps its mechanics:
/// tap a paragraph to play from it, the sounding paragraph leads, everything
/// else fades to the unselected weight.

/// Content-space bottom edges of every message, measured by preference and
/// read by the snap behavior at scroll-settle time.
private struct MessageBottomsKey: PreferenceKey {
    static var defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) {
        value.append(contentsOf: nextValue())
    }
}

final class SnapModel {
    var bottoms: [CGFloat] = []
}

/// Magnetic message edges: if a scroll would settle within `snapRadius` of a
/// message's bottom, it pops there (bottom-aligned, the reading position);
/// otherwise it runs free — so a message taller than the window stays fully
/// readable, and crossing into the next message takes a deliberate push.
@available(macOS 14.0, iOS 17.0, *)
private struct MessageSnapBehavior: ScrollTargetBehavior {
    let model: SnapModel
    static let snapRadius: CGFloat = 90

    func updateTarget(_ target: inout ScrollTarget, context: ScrollTargetBehaviorContext) {
        let container = context.containerSize.height
        guard container > 0, !model.bottoms.isEmpty else { return }
        let proposedBottom = target.rect.minY + container
        guard let nearest = model.bottoms.min(by: {
            abs($0 - proposedBottom) < abs($1 - proposedBottom)
        }) else { return }
        if abs(nearest - proposedBottom) <= Self.snapRadius {
            let maxOffset = max(context.contentSize.height - container, 0)
            target.rect.origin.y = min(max(nearest - container, 0), maxOffset)
        }
    }
}

private struct SnapIfAvailable: ViewModifier {
    let model: SnapModel
    func body(content: Content) -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            content.scrollTargetBehavior(MessageSnapBehavior(model: model))
        } else {
            content
        }
    }
}

struct TranscriptView: View {
    @ObservedObject var client: EchoClient
    /// The open lane's history, newest-first as EchoClient keeps it.
    let clips: [Clip]
    @State private var snapModel = SnapModel()

    private var ordered: [Clip] { clips.reversed() }
    private var newestId: UUID? { clips.first?.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    ForEach(ordered) { clip in
                        MessageBlock(client: client, clip: clip)
                            .id(clip.id)
                            .background(GeometryReader { g in
                                Color.clear.preference(
                                    key: MessageBottomsKey.self,
                                    value: [g.frame(in: .named("transcriptContent")).maxY])
                            })
                    }
                }
                .coordinateSpace(name: "transcriptContent")
                .padding(.horizontal, 6)
                .padding(.top, 6)
                .padding(.bottom, 14)
            }
            .onPreferenceChange(MessageBottomsKey.self) { snapModel.bottoms = $0.sorted() }
            .modifier(SnapIfAvailable(model: snapModel))
            .onAppear {
                if let id = newestId { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: newestId) { id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: client.openLane) { _ in
                if let id = newestId { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

/// One message in the transcript: a time separator, then the full text at
/// reading size. Fade rules (Ranny's spec, 08-21): unselected messages wear
/// the played-row fade; the selected message reads strong; and the moment a
/// paragraph sounds, its siblings drop to the unselected fade so the sounding
/// one carries the eye.
private struct MessageBlock: View {
    @ObservedObject var client: EchoClient
    let clip: Clip

    private static let textSize: CGFloat = 20      // 2× the old footnote body
    private let faded: Double = 0.4

    private var isSelected: Bool { client.openClip?.id == clip.id }
    private var isLive: Bool { client.nowPlayingClip?.id == clip.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            separator
            if let chunks = clip.chunks {
                ForEach(chunks, id: \.seq) { chunk in
                    Text(chunk.text)
                        .font(.system(size: Self.textSize))
                        .strikethrough(chunk.failed)
                        .opacity(paragraphOpacity(chunk.seq))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { client.jump(to: chunk.seq, in: clip) }
                }
            } else {
                Text(clip.text)
                    .font(.system(size: Self.textSize))
                    .opacity(isSelected || isLive ? 1 : faded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { client.play(clip) }
            }
        }
    }

    private func paragraphOpacity(_ seq: Int) -> Double {
        if isLive { return seq == client.currentChunk ? 1 : faded }
        return isSelected ? 1 : faded
    }

    private var separator: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            if clip.playedAt == nil { PulsingDot() }
            Text(clip.displayedAt, style: .time)
                .font(.caption).foregroundStyle(.secondary)
            Rectangle().fill(.quaternary).frame(height: 1)
        }
    }
}

/// The fixed transport bar above the transcript — everything the active card
/// used to carry: live controls (restart · pause · stop · Continue/Rendering/
/// scrubber) with the chunk counter, or a replay affordance when idle.
struct TransportBar: View {
    @ObservedObject var client: EchoClient
    @State private var scrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        HStack(spacing: 10) {
            if client.nowPlayingClip != nil {
                liveControls
            } else if let open = client.openClip {
                Button { client.play(open) } label: {
                    Label("Play again", systemImage: "play.fill").font(.callout)
                }
                .buttonStyle(.bordered)
                Spacer()
                Text(open.displayedAt, style: .time)
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer().frame(height: 24)
            }
        }
        .frame(minHeight: 30)
    }

    @ViewBuilder private var liveControls: some View {
        if let clip = client.nowPlayingClip {
            if let chunks = clip.chunks, !chunks.isEmpty {
                Text("\(min(client.currentChunk + 1, chunks.count)) of \(chunks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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
    }

    private func timeText(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
