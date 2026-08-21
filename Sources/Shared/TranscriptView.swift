import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The message pager — the window's content area, fourth pass of the cockpit
/// drive (2026-08-21, Ranny's redesign after three snap attempts died on
/// macOS's scroll internals — modern SwiftUI ScrollView isn't even
/// NSScrollView-backed, so there was never a signal to intercept).
///
/// The shape now: ONE message fills the whole text area. Small text sits
/// vertically centered with calm space around it; text taller than the box
/// scrolls within it, clamped at its own top and bottom. Pushing past an edge
/// is the page switch — an elastic pull (needle into the cell: resistance
/// first, then the pop) that slides the neighboring message in. Scrolling is
/// driven entirely by our own physics: an NSEvent local monitor takes the raw
/// scroll-wheel stream over the pager (nothing for AppKit to hide), applies
/// deltas to the inner offset, turns edge overflow into a rubber-banded pull,
/// and fires the switch past the threshold. Gesture deltas count toward the
/// pull; momentum only scrolls the inner text — crossing a message edge takes
/// a deliberate push. Tunables: threshold · rubber curve · the two springs.
///
/// iOS: the same page layout with a native inner ScrollView and no edge
/// gesture yet — the phone pass picks its own mechanism at deploy time.

// MARK: - Measurements

/// Text heights keyed by message id — during a page-switch animation BOTH
/// pages are alive and reporting; a single scalar got clobbered by whichever
/// landed last (the wrong-message/centering bug of the first pager build).
private struct TextHeightKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { max($0, $1) }
    }
}

private struct BoxHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Each paragraph's top edge within its message's content, per message —
/// what lets a page-return land ON the sounding paragraph instead of the top.
private struct ChunkFramesKey: PreferenceKey {
    static var defaultValue: [UUID: [Int: CGFloat]] = [:]
    static func reduce(value: inout [UUID: [Int: CGFloat]], nextValue: () -> [UUID: [Int: CGFloat]]) {
        value.merge(nextValue()) { a, b in a.merging(b) { $1 } }
    }
}

#if os(macOS)

// MARK: - The physics engine (macOS)

/// Owns the scroll-wheel monitor and the pull/offset state for the active
/// page. All mutation happens on the main thread (NSEvent monitors run there).
final class PagerEngine: ObservableObject {
    /// Scroll distance from the top of the overflowing text (0…maxOffset).
    @Published var innerOffset: CGFloat = 0
    /// Elastic display offset while pulling past an edge (+ = pulled at top).
    @Published var rubber: CGFloat = 0

    /// Measured text heights per message — kept across visits so returning to
    /// a page lands correctly before its next layout pass.
    @Published private(set) var heights: [UUID: CGFloat] = [:]
    /// The page the physics currently applies to.
    var currentId: UUID?
    var textH: CGFloat { currentId.flatMap { heights[$0] } ?? 0 }
    var boxH: CGFloat = 0
    /// Called with -1 (page above / older) or +1 (below / newer).
    /// Returns whether a switch actually happened (false at the ends).
    var onSwitch: ((Int) -> Bool)?
    /// Hit test: does this event belong to the pager's screen area?
    var hitTest: ((NSEvent) -> Bool)?

    /// Diagnostics sink (drive instrumentation — wired to the app log ring).
    var debugLog: ((String) -> Void)?
    /// Raw accumulated pull past an edge (signed; + = top).
    private var pull: CGFloat = 0
    /// Swallow leftovers (rest of gesture + momentum) after a switch fires.
    private var cooling = false
    private var pendingLandAtBottom = false
    /// A specific landing offset (e.g., the sounding paragraph) — wins over
    /// landAtBottom when set.
    private var pendingLandOffset: CGFloat?
    private var justPrepared = false
    private var decay: DispatchWorkItem?
    private var monitor: Any?

    static let threshold: CGFloat = 150
    static let switchSpring: Animation = .spring(response: 0.42, dampingFraction: 0.85)
    static let releaseSpring: Animation = .spring(response: 0.3, dampingFraction: 0.8)

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            self?.handle(e) ?? e
        }
    }

    func remove() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit { remove() }

    /// The view is about to switch to another page (engine-initiated).
    func prepareForNewPage(landAtBottom: Bool) {
        pull = 0
        rubber = 0
        innerOffset = 0
        pendingLandAtBottom = landAtBottom
        pendingLandOffset = nil
        justPrepared = true
    }

    /// Switch that should land at a specific content offset — the page-return
    /// to a live message lands on its sounding paragraph.
    func prepareForNewPage(landAtOffset offset: CGFloat) {
        pull = 0
        rubber = 0
        innerOffset = 0
        pendingLandAtBottom = false
        pendingLandOffset = offset
        justPrepared = true
    }

    /// The current page changed — engine-initiated (justPrepared) or from the
    /// outside (auto-play advance, lane switch, arrival). Either way the
    /// physics now applies to `id`; if we already know its height (a page
    /// revisited), the landing applies immediately.
    func pageDidChange(to id: UUID?) {
        currentId = id
        if justPrepared {
            justPrepared = false
        } else {
            pull = 0
            rubber = 0
            innerOffset = 0
            pendingLandAtBottom = false
            pendingLandOffset = nil
            cooling = false
        }
        if let id, let h = heights[id] { applyLanding(h) }
    }

    /// A page's text measured (either of the two alive during a transition —
    /// only the current one moves the physics).
    func textMeasured(id: UUID, _ h: CGFloat) {
        heights[id] = h
        if id == currentId { applyLanding(h) }
    }

    private func applyLanding(_ h: CGFloat) {
        let maxOff = max(h - boxH, 0)
        if let off = pendingLandOffset {
            pendingLandOffset = nil
            pendingLandAtBottom = false
            innerOffset = min(max(off, 0), maxOff)
            debugLog?("land offset=\(Int(innerOffset)) maxOff=\(Int(maxOff))")
        } else if pendingLandAtBottom {
            pendingLandAtBottom = false
            innerOffset = maxOff
            debugLog?("land bottom maxOff=\(Int(maxOff))")
        } else {
            innerOffset = min(innerOffset, maxOff)
        }
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard hitTest?(e) == true else { return e }
        let inGesture = e.phase.rawValue != 0
        if e.phase.contains(.began) { cooling = false }
        if cooling { return nil }

        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY
                                             : e.scrollingDeltaY * 12
        let maxOff = max(textH - boxH, 0)
        let target = innerOffset - dy       // dy > 0 = scrolling up (earlier)

        if target >= 0 && target <= maxOff {
            innerOffset = target
            if pull != 0 { springBack() }
        } else if target < 0 {
            // Pushing past the top — toward the message above (older).
            innerOffset = 0
            if inGesture {
                pull += -target
                rubber = Self.curve(pull)
                armDecay()
                if pull >= Self.threshold { attemptSwitch(-1) }
            }
        } else {
            // Pushing past the bottom — toward the message below (newer).
            innerOffset = maxOff
            if inGesture {
                pull -= target - maxOff
                rubber = Self.curve(pull)
                armDecay()
                if -pull >= Self.threshold { attemptSwitch(+1) }
            }
        }

        if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
            if abs(pull) < Self.threshold, pull != 0 { springBack() }
        }
        return nil                          // the pager owns this wheel
    }

    private func attemptSwitch(_ dir: Int) {
        if onSwitch?(dir) == true {
            cooling = true                  // eat the rest of this gesture
        } else {
            springBack()                    // no page there — just the bounce
        }
    }

    private func springBack() {
        pull = 0
        withAnimation(Self.releaseSpring) { rubber = 0 }
    }

    private func armDecay() {
        decay?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pull != 0, !self.cooling else { return }
            self.springBack()
        }
        decay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Asymptotic elastic display: early pixels move, later ones resist.
    private static func curve(_ p: CGFloat) -> CGFloat {
        let sign: CGFloat = p >= 0 ? 1 : -1
        let a = abs(p)
        return sign * 90 * a / (a + 140)
    }
}

/// Invisible AppKit resident giving the engine a real hit test (converts the
/// event's window coordinates into our bounds, flipping handled by AppKit).
private struct PagerHitView: NSViewRepresentable {
    let engine: PagerEngine

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        engine.hitTest = { [weak v] e in
            guard let v, let w = v.window, e.window === w else { return false }
            return v.bounds.contains(v.convert(e.locationInWindow, from: nil))
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

// MARK: - The pager

struct TranscriptView: View {
    @ObservedObject var client: EchoClient
    /// The open lane's history, newest-first as EchoClient keeps it.
    let clips: [Clip]

    #if os(macOS)
    @StateObject private var engine = PagerEngine()
    #endif
    /// nil = ride the newest message; set once the user navigates away.
    @State private var pageId: UUID?
    /// Direction of the last switch, for the slide transition.
    @State private var lastDir: Int = 1
    /// Paragraph top-edges per message (measured), for sounding-paragraph landings.
    @State private var chunkFrames: [UUID: [Int: CGFloat]] = [:]

    /// THE STALE-CAPTURE FIX (drive log, 14:24): the engine's onSwitch closure
    /// captures this view struct by value at onAppear — a plain `clips` array
    /// would freeze there, blinding scroll-switches to every later arrival
    /// (pull-downs stopped one short of the real newest; the button, running
    /// in the fresh view, worked fine). `client` is a reference, so deriving
    /// the list from it reads live data even inside the stale closure.
    private var ordered: [Clip] {
        let lane = client.openLane
        return client.clips.filter { lane == nil || $0.lane == lane }.reversed()
    }
    private var newestId: UUID? { ordered.last?.id }
    private var current: Clip? {
        if let pageId, let c = ordered.first(where: { $0.id == pageId }) { return c }
        return ordered.last
    }
    private var currentIndex: Int {
        guard let cur = current else { return 0 }
        return ordered.firstIndex(where: { $0.id == cur.id }) ?? ordered.count - 1
    }

    var body: some View {
        ZStack {
            if let clip = current {
                page(for: clip)
                    .id(clip.id)
                    .transition(pageTransition)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // The way home: visible whenever we're off the newest message.
            if let last = ordered.last, current?.id != last.id {
                Button { jumpToNewest() } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .padding(12)
                .help("Back to the latest message")
            }
        }
        #if os(macOS)
        .background(PagerHitView(engine: engine))
        .onAppear {
            engine.onSwitch = { dir in switchPage(dir) }
            engine.currentId = current?.id
            engine.debugLog = { [weak client] in client?.log.add("pager: \($0)") }
            engine.install()
        }
        .onDisappear { engine.remove() }
        .onPreferenceChange(TextHeightKey.self) { measured in
            for (id, h) in measured { engine.textMeasured(id: id, h) }
        }
        #endif
        .onPreferenceChange(ChunkFramesKey.self) { chunkFrames.merge($0) { $1 } }
        .onChange(of: current?.id) { id in
            #if os(macOS)
            engine.pageDidChange(to: id)
            client.log.add("pager: current idx=\(currentIndex)/\(ordered.count - 1) " +
                           "id=\(id?.uuidString.prefix(5) ?? "nil") " +
                           "last=\(ordered.last?.id.uuidString.prefix(5) ?? "nil") " +
                           "pageId=\(pageId?.uuidString.prefix(5) ?? "nil") " +
                           "live=\(client.nowPlayingClip?.id.uuidString.prefix(5) ?? "none")")
            #endif
        }
        .onChange(of: client.openClip?.id) { newId in
            // Follow selection made elsewhere (auto-play advance, taps).
            guard let newId, newId != current?.id,
                  let ni = ordered.firstIndex(where: { $0.id == newId }) else { return }
            lastDir = ni >= currentIndex ? 1 : -1
            prepareLanding(for: ordered[ni], dir: lastDir)
            withAnimation(springForSwitch) { pageId = newId }
        }
        .onChange(of: newestId) { _ in
            if pageId == nil { lastDir = 1 }   // riding the newest: slide up
        }
        .onChange(of: client.openLane) { _ in
            pageId = nil                        // fresh lane: its newest page
        }
    }

    private var springForSwitch: Animation {
        #if os(macOS)
        PagerEngine.switchSpring
        #else
        .spring(response: 0.42, dampingFraction: 0.85)
        #endif
    }

    private var pageTransition: AnyTransition {
        lastDir < 0
        ? .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                      removal: .move(edge: .bottom).combined(with: .opacity))
        : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                      removal: .move(edge: .top).combined(with: .opacity))
    }

    /// -1 = the message above (older) · +1 = below (newer). Returns whether
    /// there was a page to switch to.
    private func switchPage(_ dir: Int) -> Bool {
        let ni = currentIndex + dir
        guard ordered.indices.contains(ni) else { return false }
        let next = ordered[ni]
        lastDir = dir
        client.log.add("pager: switch dir=\(dir) \(currentIndex)→\(ni)/\(ordered.count - 1) " +
                       "to=\(next.id.uuidString.prefix(5)) " +
                       "isLive=\(next.id == client.nowPlayingClip?.id)")
        prepareLanding(for: next, dir: dir)
        withAnimation(springForSwitch) { pageId = next.id }
        client.select(next)
        return true
    }

    /// Where a page switch lands. A LIVE message wins: land on its sounding
    /// paragraph so the highlight picks right back up (Ranny, 08-21).
    /// Otherwise: entering from below lands at the bottom of the message
    /// above (the reading position); entering from above lands at its top.
    private func prepareLanding(for clip: Clip, dir: Int) {
        #if os(macOS)
        let liveMatch = clip.id == client.nowPlayingClip?.id
        if liveMatch, let y = chunkFrames[clip.id]?[client.currentChunk] {
            client.log.add("pager: landing on chunk \(client.currentChunk) y=\(Int(y))")
            engine.prepareForNewPage(landAtOffset: max(y - 80, 0))
        } else {
            client.log.add("pager: landing \(dir < 0 ? "bottom" : "top") " +
                           "(liveMatch=\(liveMatch) frames=\(chunkFrames[clip.id]?.count ?? -1) " +
                           "chunk=\(client.currentChunk))")
            engine.prepareForNewPage(landAtBottom: dir < 0)
        }
        #endif
    }

    /// The floating button: back to the newest message, landing at its bottom
    /// (the latest words). pageId returns to nil so the pager rides new
    /// arrivals again.
    private func jumpToNewest() {
        guard let last = ordered.last, current?.id != last.id else { return }
        lastDir = 1
        // A live newest lands on its sounding paragraph; otherwise at its
        // latest words.
        if last.id == client.nowPlayingClip?.id {
            prepareLanding(for: last, dir: 1)
        } else {
            #if os(macOS)
            engine.prepareForNewPage(landAtBottom: true)
            #endif
        }
        withAnimation(springForSwitch) { pageId = nil }
        client.select(last)
    }

    @ViewBuilder private func page(for clip: Clip) -> some View {
        VStack(spacing: 8) {
            pageHeader(clip)
            GeometryReader { box in
                MessageBlock(client: client, clip: clip)
                    .frame(width: box.size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TextHeightKey.self,
                                               value: [clip.id: g.size.height])
                    })
                    .offset(y: pageOffset(for: clip, boxHeight: box.size.height))
                    .frame(width: box.size.width, height: box.size.height, alignment: .topLeading)
                    .clipped()
                    .contentShape(Rectangle())
                    .preference(key: BoxHeightKey.self, value: box.size.height)
            }
        }
        .onPreferenceChange(BoxHeightKey.self) { h in
            #if os(macOS)
            engine.boxH = h
            #endif
        }
    }

    /// Each alive page (two, mid-transition) positions by its OWN measured
    /// height; only the current page carries the live physics offsets.
    private func pageOffset(for clip: Clip, boxHeight: CGFloat) -> CGFloat {
        #if os(macOS)
        let isCurrent = clip.id == engine.currentId
        let textH = engine.heights[clip.id] ?? 0
        let rubber = isCurrent ? engine.rubber : 0
        if textH > 0, textH <= boxHeight {
            return (boxHeight - textH) / 2 + rubber          // centered, calm
        }
        return (isCurrent ? -engine.innerOffset : 0) + rubber
        #else
        return 0
        #endif
    }

    private func pageHeader(_ clip: Clip) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            if clip.playedAt == nil { PulsingDot() }
            Text(clip.displayedAt, style: .time)
                .font(.caption).foregroundStyle(.secondary)
            Text("\(currentIndex + 1)/\(ordered.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Rectangle().fill(.quaternary).frame(height: 1)
        }
    }
}

// MARK: - One message's text

/// The full text of one message at reading size, centered. Fade rules
/// (Ranny's spec): the page is the selected message and reads strong; while
/// audio plays only the sounding paragraph stays strong. Tap a paragraph to
/// play from it.
private struct MessageBlock: View {
    @ObservedObject var client: EchoClient
    let clip: Clip

    private static let textSize: CGFloat = 17
    private let faded: Double = 0.4

    private var isLive: Bool { client.nowPlayingClip?.id == clip.id }

    var body: some View {
        #if os(macOS)
        content
        #else
        ScrollView { content }
        #endif
    }

    private var content: some View {
        VStack(alignment: .center, spacing: 12) {
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
                        .background(GeometryReader { g in
                            Color.clear.preference(
                                key: ChunkFramesKey.self,
                                value: [clip.id: [chunk.seq: g.frame(in: .named("msgContent")).minY]])
                        })
                }
            } else {
                Text(clip.text)
                    .font(.system(size: Self.textSize))
                    .multilineTextAlignment(.center)
                    .opacity(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .onTapGesture { client.play(clip) }
            }
        }
        .padding(.horizontal, 12)
        // Breathing room at both ends — inside the measured height, so a tall
        // message's scroll range includes it and small text stays centered.
        .padding(.vertical, 28)
        // Paragraph positions measure against this space — the same padded
        // block whose height TextHeightKey reports, so offsets line up.
        .coordinateSpace(name: "msgContent")
    }

    private func paragraphOpacity(_ seq: Int) -> Double {
        if isLive { return seq == client.currentChunk ? 1 : faded }
        return 1
    }
}

// MARK: - Transport

/// The single control row (cockpit rounding, 08-21): media transport on the
/// left using the free space, the mode cluster pinned right — auto-play
/// (bolt), reasoning/full-play (segmented icons), mute (speaker). "Play
/// again" is gone: any paragraph is a play button. The old status row died —
/// status + Settings live in the app menu now; quitting the app is the off
/// switch. The height saved is reserved for user input, coming later.
struct TransportBar: View {
    @ObservedObject var client: EchoClient
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("walkieMode") private var walkieMode = true
    @AppStorage("muted") private var muted = false
    @State private var scrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        HStack(spacing: 12) {
            if client.nowPlayingClip != nil {
                liveControls
            } else {
                if let open = client.openClip {
                    Text(open.displayedAt, style: .time)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            modeCluster
        }
        .frame(minHeight: 30)
    }

    private var modeCluster: some View {
        HStack(spacing: 12) {
            Button { autoPlay.toggle() } label: {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(autoPlay ? AnyShapeStyle(.tint)
                                              : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(autoPlay ? "Auto-play on — arrivals play by the rail's routing. Click to require a tap."
                           : "Auto-play off — messages wait for your tap.")
            Picker("", selection: $walkieMode) {
                Image(systemName: "playpause.fill").tag(true)
                Image(systemName: "play.fill").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 76)
            .help(walkieMode ? "Reasoning — pause at each part; Continue plays the next."
                             : "Full play — messages play straight through.")
            Button { muted.toggle() } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(muted ? AnyShapeStyle(.orange)
                                           : AnyShapeStyle(.tint))
            }
            .buttonStyle(.plain)
            .help(muted ? "Muted — messages arrive and wait silently. Click to unmute."
                        : "Mute — keep receiving, never auto-play.")
        }
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
