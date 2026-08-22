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

/// Text heights keyed by PAGE id — during a page-switch animation BOTH pages
/// are alive and reporting; a single scalar got clobbered by whichever landed
/// last (the wrong-message/centering bug of the first pager build). Keys are
/// Strings since the input build: a page is a TURN, whose id must stay stable
/// while clips accrete onto it (prompt → opening → final).
private struct TextHeightKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { max($0, $1) }
    }
}

private struct BoxHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#if os(iOS)
/// iOS page-switch signal: the inner scroll's content frame (minY + height)
/// in the page's coordinate space — overscroll past either edge, held far
/// enough, flips to the neighboring message (pull-to-refresh mechanics).
private struct PhoneScrollKey: PreferenceKey {
    static var defaultValue: [CGFloat] = []
    static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) {
        let n = nextValue()
        if !n.isEmpty { value = n }
    }
}
#endif

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

    /// Measured text heights per page — kept across visits so returning to
    /// a page lands correctly before its next layout pass.
    @Published private(set) var heights: [String: CGFloat] = [:]
    /// The page the physics currently applies to.
    var currentId: String?
    var textH: CGFloat { currentId.flatMap { heights[$0] } ?? 0 }
    var boxH: CGFloat = 0
    /// Called with -1 (page above / older) or +1 (below / newer).
    /// Returns whether a switch actually happened (false at the ends).
    var onSwitch: ((Int) -> Bool)?
    /// Hit test: does this event belong to the pager's screen area?
    var hitTest: ((NSEvent) -> Bool)?

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
    func pageDidChange(to id: String?) {
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
    func textMeasured(id: String, _ h: CGFloat) {
        heights[id] = h
        if id == currentId { applyLanding(h) }
    }

    private func applyLanding(_ h: CGFloat) {
        let maxOff = max(h - boxH, 0)
        if let off = pendingLandOffset {
            pendingLandOffset = nil
            pendingLandAtBottom = false
            innerOffset = min(max(off, 0), maxOff)
        } else if pendingLandAtBottom {
            pendingLandAtBottom = false
            innerOffset = maxOff
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

/// One pager page since the input build (2026-08-21 night): a TURN — his
/// prompt bubble plus the opening and final that answered it, grouped by
/// (lane, prompt id). Clips without a turn id (pre-input history, `hear`
/// replays) page alone, exactly as before. The id is the group key, so it
/// stays stable while the turn's pieces accrete onto the same page.
struct Turn: Identifiable, Equatable {
    let id: String
    let clips: [Clip]          // oldest first: bubble, opening, final
}

struct TranscriptView: View {
    @ObservedObject var client: EchoClient
    /// The open lane's history, newest-first as EchoClient keeps it.
    let clips: [Clip]

    #if os(macOS)
    @StateObject private var engine = PagerEngine()
    #endif
    /// nil = ride the newest turn; set once the user navigates away.
    @State private var pageId: String?
    /// Direction of the last switch, for the slide transition.
    @State private var lastDir: Int = 1
    /// Paragraph top-edges per clip (measured in the turn's content space),
    /// for sounding-paragraph landings.
    @State private var chunkFrames: [UUID: [Int: CGFloat]] = [:]

    /// THE STALE-CAPTURE FIX (drive log, 14:24): the engine's onSwitch closure
    /// captures this view struct by value at onAppear — a plain `clips` array
    /// would freeze there, blinding scroll-switches to every later arrival
    /// (pull-downs stopped one short of the real newest; the button, running
    /// in the fresh view, worked fine). `client` is a reference, so deriving
    /// the list from it reads live data even inside the stale closure.
    /// The grouping itself lives on the client, which CACHES it: this getter
    /// is read five-plus times per body pass and the body re-runs inside the
    /// rail's animation, so rebuilding here was O(clips) many times a frame.
    private var ordered: [Turn] { client.turns(for: client.openLane) }
    private var newestId: String? { ordered.last?.id }
    private var current: Turn? {
        if let pageId, let t = ordered.first(where: { $0.id == pageId }) { return t }
        return ordered.last
    }
    private var currentIndex: Int {
        guard let cur = current else { return 0 }
        return ordered.firstIndex(where: { $0.id == cur.id }) ?? ordered.count - 1
    }
    private func turnIndex(containing clipId: UUID) -> Int? {
        ordered.firstIndex(where: { $0.clips.contains(where: { $0.id == clipId }) })
    }

    var body: some View {
        ZStack {
            if let turn = current {
                page(for: turn)
                    .id(turn.id)
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
            #endif
        }
        .onChange(of: client.openClip?.id) { newId in
            // Follow selection made elsewhere (auto-play advance, taps, an
            // arriving prompt bubble) — to the TURN that holds the clip.
            guard let newId, let ni = turnIndex(containing: newId),
                  ordered[ni].id != current?.id else { return }
            lastDir = ni >= currentIndex ? 1 : -1
            prepareLanding(for: ordered[ni], dir: lastDir)
            withAnimation(springForSwitch) { pageId = ordered[ni].id }
        }
        .onChange(of: client.nowPlayingClip?.id) { npId in
            // A message starting INSIDE the current page (the turn's final
            // auto-playing under its bubble) has no page switch to land it —
            // glide the view to its sounding paragraph here instead.
            #if os(macOS)
            guard let npId, let cur = current,
                  cur.clips.contains(where: { $0.id == npId }),
                  let y = chunkFrames[npId]?[client.currentChunk] else { return }
            let maxOff = max((engine.heights[cur.id] ?? 0) - engine.boxH, 0)
            guard maxOff > 0 else { return }
            withAnimation(PagerEngine.switchSpring) {
                engine.innerOffset = min(max(y - 80, 0), maxOff)
            }
            #endif
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

    #if os(iOS)
    @State private var phoneSwitchCooling = false

    /// The phone's page switch: fires once when the bounce carries past the
    /// threshold, re-arms when the scroll settles back near rest.
    private func phoneOverscroll(minY: CGFloat, contentH: CGFloat,
                                 viewportH: CGFloat) {
        let topPull = minY                                   // > 0 = pulled past top
        let bottomPull = viewportH - (minY + max(contentH, viewportH))
        if phoneSwitchCooling {
            if topPull < 8 && bottomPull < 8 { phoneSwitchCooling = false }
            return
        }
        if topPull > 70 {
            phoneSwitchCooling = true
            _ = switchPage(-1)
        } else if bottomPull > 70 {
            phoneSwitchCooling = true
            _ = switchPage(1)
        }
    }
    #endif

    /// -1 = the turn above (older) · +1 = below (newer). Returns whether
    /// there was a page to switch to.
    private func switchPage(_ dir: Int) -> Bool {
        let ni = currentIndex + dir
        guard ordered.indices.contains(ni) else { return false }
        let next = ordered[ni]
        lastDir = dir
        prepareLanding(for: next, dir: dir)
        withAnimation(springForSwitch) { pageId = next.id }
        if let l = next.clips.last { client.select(l) }
        return true
    }

    /// Where a page switch lands. A LIVE turn wins: land on the sounding
    /// paragraph so the highlight picks right back up (Ranny, 08-21).
    /// Otherwise: entering from below lands at the bottom of the turn
    /// above (the reading position); entering from above lands at its top.
    private func prepareLanding(for turn: Turn, dir: Int) {
        #if os(macOS)
        if let np = client.nowPlayingClip,
           turn.clips.contains(where: { $0.id == np.id }),
           let y = chunkFrames[np.id]?[client.currentChunk] {
            engine.prepareForNewPage(landAtOffset: max(y - 80, 0))
        } else {
            engine.prepareForNewPage(landAtBottom: dir < 0)
        }
        #endif
    }

    /// The floating button: back to the newest turn, landing at its bottom
    /// (the latest words). pageId returns to nil so the pager rides new
    /// arrivals again.
    private func jumpToNewest() {
        guard let last = ordered.last, current?.id != last.id else { return }
        lastDir = 1
        // A live newest lands on its sounding paragraph; otherwise at its
        // latest words.
        if let np = client.nowPlayingClip,
           last.clips.contains(where: { $0.id == np.id }) {
            prepareLanding(for: last, dir: 1)
        } else {
            #if os(macOS)
            engine.prepareForNewPage(landAtBottom: true)
            #endif
        }
        withAnimation(springForSwitch) { pageId = nil }
        if let l = last.clips.last { client.select(l) }
    }

    @ViewBuilder private func page(for turn: Turn) -> some View {
        VStack(spacing: 8) {
            pageHeader(turn)
            #if os(macOS)
            GeometryReader { box in
                turnContent(turn)
                    .frame(width: box.size.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TextHeightKey.self,
                                               value: [turn.id: g.size.height])
                    })
                    .offset(y: pageOffset(for: turn, boxHeight: box.size.height))
                    .frame(width: box.size.width, height: box.size.height, alignment: .topLeading)
                    .clipped()
                    .contentShape(Rectangle())
                    .preference(key: BoxHeightKey.self, value: box.size.height)
            }
            #else
            // iOS: native scrolling inside the page; overscroll past either
            // edge (the bounce) is the page switch — pull down hard at the
            // top for the previous turn, up at the bottom for the next.
            GeometryReader { outer in
                ScrollView {
                    turnContent(turn)
                        .background(GeometryReader { g in
                            Color.clear.preference(
                                key: PhoneScrollKey.self,
                                value: [g.frame(in: .named("pageScroll")).minY,
                                        g.size.height])
                        })
                }
                .coordinateSpace(name: "pageScroll")
                .modifier(AlwaysBounce())
                .onPreferenceChange(PhoneScrollKey.self) { v in
                    guard v.count == 2 else { return }
                    phoneOverscroll(minY: v[0], contentH: v[1],
                                    viewportH: outer.size.height)
                }
            }
            #endif
        }
        .onPreferenceChange(BoxHeightKey.self) { h in
            #if os(macOS)
            engine.boxH = h
            #endif
        }
    }

    /// The page body: his bubble, then Nic's opening/final blocks — the whole
    /// turn on one page. The vertical breathing room and the paragraph
    /// coordinate space live HERE (they were MessageBlock's when a page was
    /// one clip) so landings work across the turn's pieces.
    private func turnContent(_ turn: Turn) -> some View {
        VStack(alignment: .center, spacing: 22) {
            ForEach(turn.clips) { clip in
                if clip.isUser {
                    PromptBubble(clip: clip)
                } else {
                    MessageBlock(client: client, clip: clip)
                }
            }
        }
        .padding(.vertical, 28)
        .coordinateSpace(name: "msgContent")
    }

    /// Each alive page (two, mid-transition) positions by its OWN measured
    /// height; only the current page carries the live physics offsets.
    private func pageOffset(for turn: Turn, boxHeight: CGFloat) -> CGFloat {
        #if os(macOS)
        let isCurrent = turn.id == engine.currentId
        let textH = engine.heights[turn.id] ?? 0
        let rubber = isCurrent ? engine.rubber : 0
        if textH > 0, textH <= boxHeight {
            return (boxHeight - textH) / 2 + rubber          // centered, calm
        }
        return (isCurrent ? -engine.innerOffset : 0) + rubber
        #else
        return 0
        #endif
    }

    private func pageHeader(_ turn: Turn) -> some View {
        let stamp = turn.clips.first?.displayedAt ?? Date()
        let unheard = turn.clips.contains { $0.playedAt == nil && !$0.isUser }
        return HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            if unheard { PulsingDot() }
            Text(stamp, style: .time)
                .font(.caption).foregroundStyle(.secondary)
            Text("\(currentIndex + 1)/\(ordered.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Rectangle().fill(.quaternary).frame(height: 1)
        }
    }
}

#if os(iOS)
/// Short messages can't bounce without this (no bounce = no page switch).
private struct AlwaysBounce: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content.scrollBounceBehavior(.always, axes: .vertical)
        } else {
            content
        }
    }
}
#endif

// MARK: - One message's text

/// Reading typography (Settings → Reading): family + size are the reader's
/// choice. Default = Apple's serif reading face, New York — "the Apple SF I
/// liked" (Ranny); plain SF stays one tap away. Shared by the message blocks
/// and the prompt bubbles so the whole turn reads as one page.
func readingFont(_ key: String, size: Double) -> Font {
    switch key {
    case "system": return .system(size: size)
    case "mono": return .system(size: size, design: .monospaced)
    case "menlo": return .custom("Menlo", size: size)
    case "iowan": return .custom("Iowan Old Style", size: size)
    case "charter": return .custom("Charter", size: size)
    case "georgia": return .custom("Georgia", size: size)
    case "palatino": return .custom("Palatino", size: size)
    case "ubuntu": return .custom("Ubuntu", size: size)
    default: return .system(size: size, design: .serif)   // newyork
    }
}

/// The full text of one message at reading size, centered. Fade rules
/// (Ranny's spec): the page is the selected message and reads strong; while
/// audio plays only the sounding paragraph stays strong. Tap a paragraph to
/// play from it.
private struct MessageBlock: View {
    @ObservedObject var client: EchoClient
    let clip: Clip

    @AppStorage("messageFont") private var messageFontKey = "newyork"
    @AppStorage("messageFontSize") private var messageFontSize = 17.0
    private let faded: Double = 0.4

    private var messageFont: Font { readingFont(messageFontKey, size: messageFontSize) }

    private var isLive: Bool { client.nowPlayingClip?.id == clip.id }

    var body: some View { content }

    /// Nic's side of the turn (Ranny, input polish): a bubble too — muted
    /// against the ground (his inputs stay the lighter tone), text set LEFT,
    /// pinned leading with a trailing inset mirroring the prompt bubble.
    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let chunks = clip.chunks {
                    ForEach(chunks, id: \.seq) { chunk in
                        Text(chunk.text)
                            .font(messageFont)
                            .lineSpacing(5)
                            .multilineTextAlignment(.leading)
                            .strikethrough(chunk.failed)
                            .opacity(paragraphOpacity(chunk.seq))
                            .frame(maxWidth: .infinity, alignment: .leading)
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
                        .font(messageFont)
                        .lineSpacing(5)
                        .multilineTextAlignment(.leading)
                        .opacity(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { client.play(clip) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .stroke(Color.primary.opacity(0.05), lineWidth: 1)
                    )
            )
            Spacer(minLength: 44)
        }
        .padding(.horizontal, 12)
        // Breathing room + the "msgContent" coordinate space moved UP to the
        // turn container (input build) — paragraph positions measure against
        // the whole turn, which is what the pager's landings scroll.
    }

    private func paragraphOpacity(_ seq: Int) -> Double {
        if isLive { return seq == client.currentChunk ? 1 : faded }
        return 1
    }
}

// MARK: - His side of the turn

/// One of Ranny's prompts, as sent — from either surface (the Echo field or
/// the terminal; the status shim mirrors both). A satin bubble a shade
/// lighter than the ground, pinned trailing: the chat idiom marks whose
/// voice it is, and the lighter tone is the spec's "user inputs lighter".
private struct PromptBubble: View {
    let clip: Clip

    @AppStorage("messageFont") private var messageFontKey = "newyork"
    @AppStorage("messageFontSize") private var messageFontSize = 17.0

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            Text(clip.text)
                .font(readingFont(messageFontKey, size: max(messageFontSize - 1, 12)))
                .lineSpacing(4)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 17, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                        )
                )
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Transport

/// The control surface (cockpit rounding, 08-21; reshaped for the input
/// build): the mode cluster is auto-play (speaker — it inherited mute's icon
/// when mute retired as redundant) + reasoning/full-play (segmented icons).
/// "Play again" is gone: any paragraph is a play button. Mac = one row,
/// transport left, modes right. iPhone = TWO rows (the narrow width made one
/// claustrophobic): counter + modes up top, the media transport full-width
/// beneath, only while something is in flight.
struct TransportBar: View {
    @ObservedObject var client: EchoClient
    @AppStorage("autoPlay") private var autoPlay = true
    @AppStorage("walkieMode") private var walkieMode = true
    @State private var scrubbing = false
    @State private var scrubTime: TimeInterval = 0

    var body: some View {
        // Both platforms (input polish): the top row belongs to configuration
        // only — mode chip, auto-play, walkie toggle, counter/time far left.
        // The media transport gets its own full-width row beneath, present
        // only while something is in flight.
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                leadingInfo
                Spacer()
                modeCluster
            }
            if client.nowPlayingClip != nil {
                HStack(spacing: 12) { transportControls }
            }
        }
        .frame(minHeight: 30)
        // Transport layout changes (play/pause/stop/gate/render) glide
        // instead of snapping (Ranny, orb polish pass).
        .animation(.easeInOut(duration: 0.22), value: transportKey)
    }

    private var transportKey: String {
        "\(client.nowPlayingClip != nil)|\(client.isPaused)|" +
        "\(client.awaitingContinue)|\(client.awaitingRender)"
    }

    /// Far left: the chunk counter while playing, the open turn's time otherwise.
    @ViewBuilder private var leadingInfo: some View {
        if let clip = client.nowPlayingClip {
            if let chunks = clip.chunks, !chunks.isEmpty {
                Text("\(min(client.currentChunk + 1, chunks.count)) of \(chunks.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } else if let open = client.openClip {
            Text(open.displayedAt, style: .time)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modeCluster: some View {
        HStack(spacing: 8) {
            modeChip
            Button { autoPlay.toggle() } label: {
                Image(systemName: autoPlay ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .foregroundStyle(autoPlay ? AnyShapeStyle(.tint)
                                              : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help(autoPlay ? "Auto-play on — arrivals play by the rail's routing. Click to make messages wait for your tap."
                           : "Auto-play off — messages arrive silently and wait for your tap.")
            Picker("", selection: $walkieMode) {
                Image(systemName: "brain").tag(true)
                Image(systemName: "infinity").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 76)
            .help(walkieMode ? "Reasoning — pause at each part; Continue plays the next."
                             : "Full play — messages play straight through.")
        }
    }

    /// The open lane's permission mode, colored, as a chip. Tapping asks the
    /// server to cycle it (shift+tab into the session) and re-probe.
    @ViewBuilder private var modeChip: some View {
        if let lane = client.openLane {
            let mode = client.laneStates[lane]?.mode
            Button { client.cycleMode(lane) } label: {
                HStack(spacing: 5) {
                    Circle().fill(Self.modeColor(mode))
                        .frame(width: 6, height: 6)
                    Text(Self.modeLabel(mode))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Self.modeColor(mode))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Self.modeColor(mode).opacity(0.13)))
            }
            .buttonStyle(.plain)
            .help("Permission mode of this lane's session — click to cycle (shift+tab).")
        }
    }

    static func modeLabel(_ mode: String?) -> String {
        switch mode {
        case "default": return "default"
        case "acceptEdits": return "accept edits"
        case "plan": return "plan"
        case "auto", "dontAsk": return "auto"
        case "bypassPermissions": return "bypass"
        default: return "mode"
        }
    }

    static func modeColor(_ mode: String?) -> Color {
        switch mode {
        case "default": return .gray
        case "acceptEdits": return .yellow
        case "plan": return .green
        case "auto", "dontAsk": return .orange
        case "bypassPermissions": return .red
        default: return .gray
        }
    }

    @ViewBuilder private var transportControls: some View {
        if client.nowPlayingClip != nil {
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
