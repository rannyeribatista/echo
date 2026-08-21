import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The transcript — the window's content area since the cockpit drive
/// (2026-08-21, Ranny's spec): the open lane's messages as one chat-style
/// scroll, oldest at the top, the current message living at the bottom.
/// Message text is 17pt, centered, unboxed; separators carry the time; the
/// transport lives in a fixed bar above (TransportBar). Tap a paragraph to
/// play from it; the sounding paragraph leads, everything else fades.
///
/// MAGNETIC EDGES, third pass. Pass 1 (ScrollTargetBehavior) and pass 2
/// (GeometryReader offset preference) both died the same death: on macOS the
/// AppKit scroll bridge neither consults SwiftUI's target behaviors nor
/// re-evaluates geometry during a native trackpad scroll — no signal, no
/// snap (Ranny's two drive reports). The signal now comes from AppKit
/// itself: an embedded NSView finds its enclosing NSScrollView and observes
/// the clip view's boundsDidChange — the ground truth of scrolling on macOS.
/// A settle timer on the default runloop mode fires only after the gesture
/// ends; if the viewport bottom rests within `snapRadius` of a message's
/// bottom edge, a spring pops it there (bottom-aligned, the reading
/// position). Long messages scroll free inside; crossing an edge takes a
/// deliberate push. Tunables: snapRadius + snapSpring. iOS: plain scroll for
/// now — the phone pass picks its own mechanism at deploy time.

/// Content-space bottom edge of every message, keyed by clip id. Measured at
/// layout time (which macOS does honor), consumed at scroll-settle time.
private struct MessageBottomsKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

#if os(macOS)
/// Invisible resident of the scroll content: reports (offset, viewportH,
/// contentH) whenever a native scroll settles.
private struct ScrollSettleWatcher: NSViewRepresentable {
    let onSettle: (_ offset: CGFloat, _ viewportH: CGFloat, _ contentH: CGFloat) -> Void

    func makeNSView(context: Context) -> WatcherView {
        let v = WatcherView()
        v.onSettle = onSettle
        return v
    }

    func updateNSView(_ nsView: WatcherView, context: Context) {
        nsView.onSettle = onSettle
    }

    final class WatcherView: NSView {
        var onSettle: ((CGFloat, CGFloat, CGFloat) -> Void)?
        private var observer: NSObjectProtocol?
        private var settleTimer: Timer?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard observer == nil, let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.scrolled() }
        }

        private func scrolled() {
            settleTimer?.invalidate()
            // Default runloop mode on purpose: while the trackpad gesture is
            // live the runloop sits in event-tracking mode and this timer
            // waits — so "fired" genuinely means "the hand let go".
            settleTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
                self?.settled()
            }
        }

        private func settled() {
            guard let scroll = enclosingScrollView, let doc = scroll.documentView else { return }
            let clip = scroll.contentView
            onSettle?(clip.bounds.origin.y, clip.bounds.height, doc.frame.height)
        }

        deinit {
            if let o = observer { NotificationCenter.default.removeObserver(o) }
            settleTimer?.invalidate()
        }
    }
}
#endif

struct TranscriptView: View {
    @ObservedObject var client: EchoClient
    /// The open lane's history, newest-first as EchoClient keeps it.
    let clips: [Clip]

    @State private var bottoms: [UUID: CGFloat] = [:]

    private static let bottomAnchor = "transcript-bottom"
    /// How sticky a message edge is (pt): settle inside this radius and the
    /// scroll pops to the boundary; beyond it, it stays where you left it.
    private static let snapRadius: CGFloat = 90
    private static let snapSpring: Animation = .spring(response: 0.35, dampingFraction: 0.78)

    private var ordered: [Clip] { clips.reversed() }
    private var newestId: UUID? { clips.first?.id }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .center, spacing: 30) {
                        ForEach(ordered) { clip in
                            MessageBlock(client: client, clip: clip)
                                .id(clip.id)
                                .background(GeometryReader { g in
                                    Color.clear.preference(
                                        key: MessageBottomsKey.self,
                                        value: [clip.id: g.frame(in: .named("transcriptContent")).maxY])
                                })
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                    // Breathing room over the window edge + a true bottom
                    // anchor so "scrolled to the end" shows the last line.
                    Color.clear.frame(height: 20)
                        .id(Self.bottomAnchor)
                }
                .coordinateSpace(name: "transcriptContent")
                .background(settleWatcher(proxy))
            }
            .onPreferenceChange(MessageBottomsKey.self) { bottoms = $0 }
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            .onChange(of: newestId) { _ in
                withAnimation { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            }
            .onChange(of: client.openLane) { _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    @ViewBuilder private func settleWatcher(_ proxy: ScrollViewProxy) -> some View {
        #if os(macOS)
        ScrollSettleWatcher { offset, viewportH, contentH in
            performSnap(offset: offset, viewportH: viewportH, contentH: contentH, proxy: proxy)
        }
        #else
        Color.clear
        #endif
    }

    private func performSnap(offset: CGFloat, viewportH: CGFloat, contentH: CGFloat,
                             proxy: ScrollViewProxy) {
        guard viewportH > 0, contentH > viewportH, !bottoms.isEmpty else { return }
        let viewportBottom = offset + viewportH
        guard let nearest = bottoms.min(by: {
            abs($0.value - viewportBottom) < abs($1.value - viewportBottom)
        }) else { return }
        let distance = abs(nearest.value - viewportBottom)
        if distance > 2, distance <= Self.snapRadius {
            withAnimation(Self.snapSpring) {
                proxy.scrollTo(nearest.key, anchor: .bottom)
            }
        }
    }
}

/// One message in the transcript: a time separator, then the full text at
/// reading size, centered. Fade rules (Ranny's spec, 08-21): unselected
/// messages wear the played-row fade; the selected message reads strong; and
/// the moment a paragraph sounds, its siblings drop to the unselected fade so
/// the sounding one carries the eye.
private struct MessageBlock: View {
    @ObservedObject var client: EchoClient
    let clip: Clip

    private static let textSize: CGFloat = 17
    private let faded: Double = 0.4

    private var isSelected: Bool { client.openClip?.id == clip.id }
    private var isLive: Bool { client.nowPlayingClip?.id == clip.id }

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            separator
            if let chunks = clip.chunks {
                ForEach(chunks, id: \.seq) { chunk in
                    Text(chunk.text)
                        .font(.system(size: Self.textSize))
                        .multilineTextAlignment(.center)
                        .strikethrough(chunk.failed)
                        .opacity(paragraphOpacity(chunk.seq))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                        .onTapGesture { client.jump(to: chunk.seq, in: clip) }
                }
            } else {
                Text(clip.text)
                    .font(.system(size: Self.textSize))
                    .multilineTextAlignment(.center)
                    .opacity(isSelected || isLive ? 1 : faded)
                    .frame(maxWidth: .infinity, alignment: .center)
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
