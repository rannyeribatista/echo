import Foundation
import SwiftUI

/// One chunk of a walkie (v2) message. Its text is known the moment the
/// manifest lands — the Mac announces the whole message up front — while the
/// audio file appears here only once the Mac renders it and we download it.
struct ClipChunk: Codable, Equatable {
    let seq: Int
    let text: String
    var fileName: String?    // audio inside ClipStore's directory; nil = not here yet
    var duration: Double?
    var failed: Bool         // the Mac gave up on this chunk — playback skips it

    init(seq: Int, text: String) {
        self.seq = seq
        self.text = text
        self.fileName = nil
        self.duration = nil
        self.failed = false
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        text = try c.decode(String.self, forKey: .text)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
    }
}

/// One received voice message. Codable because the last 24 hours of these
/// persist across launches (ClipStore). Legacy clips are one audio file;
/// walkie messages carry a chunk list and gate at each boundary.
struct Clip: Identifiable, Codable, Equatable {
    let id: UUID
    let msgId: String?      // walkie message id from the Mac; nil = legacy clip
    let text: String        // what Nic says (sent by the Mac for display)
    let lane: String        // which session sent it ("core", "studium", "home"…); "" = untagged
    let label: String       // first words of the message — what the row shows
    let fileName: String    // legacy audio file; "" for walkie messages
    var chunks: [ClipChunk]?    // nil = legacy single-file clip
    var isComplete: Bool        // walkie: manifest final + every chunk settled here
    let sentAt: Date?       // when the Mac rendered it (from the tag sidecar)
    let receivedAt: Date
    var playedAt: Date?     // nil = unplayed (the pulsing dot)
    /// Input phase (2026-08-21): "user" = one of HIS prompts, mirrored by the
    /// status shim — rendered as a bubble, never played. nil/anything else =
    /// Nic speaking.
    let role: String?
    /// The turn id (harness prompt_id, or the shim's synthetic fallback) —
    /// what groups a user bubble + opening + final onto one pager page.
    let promptId: String?

    init(id: UUID, msgId: String? = nil, text: String, lane: String, label: String,
         fileName: String, chunks: [ClipChunk]? = nil, isComplete: Bool = true,
         sentAt: Date?, receivedAt: Date, playedAt: Date?,
         role: String? = nil, promptId: String? = nil) {
        self.id = id
        self.msgId = msgId
        self.text = text
        self.lane = lane
        self.label = label
        self.fileName = fileName
        self.chunks = chunks
        self.isComplete = isComplete
        self.sentAt = sentAt
        self.receivedAt = receivedAt
        self.playedAt = playedAt
        self.role = role
        self.promptId = promptId
    }

    var isUser: Bool { role == "user" }

    /// Decode tolerates pre-walkie clips.json: the new fields default to a
    /// complete, single-file clip.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        msgId = try c.decodeIfPresent(String.self, forKey: .msgId)
        text = try c.decode(String.self, forKey: .text)
        lane = try c.decode(String.self, forKey: .lane)
        label = try c.decode(String.self, forKey: .label)
        fileName = try c.decode(String.self, forKey: .fileName)
        chunks = try c.decodeIfPresent([ClipChunk].self, forKey: .chunks)
        isComplete = try c.decodeIfPresent(Bool.self, forKey: .isComplete) ?? true
        sentAt = try c.decodeIfPresent(Date.self, forKey: .sentAt)
        receivedAt = try c.decode(Date.self, forKey: .receivedAt)
        playedAt = try c.decodeIfPresent(Date.self, forKey: .playedAt)
        role = try c.decodeIfPresent(String.self, forKey: .role)
        promptId = try c.decodeIfPresent(String.self, forKey: .promptId)
    }

    /// Rendered-on-the-Mac time when tagged, else arrival time — matters for
    /// clips that sat queued on the Mac before the phone connected.
    var displayedAt: Date { sentAt ?? receivedAt }

    /// Fallback label when the Mac didn't send one (old server): the first
    /// handful of words of the spoken text.
    static func defaultLabel(for text: String) -> String {
        text.split(separator: " ").prefix(10).joined(separator: " ")
    }
}

/// Connection health, shown honestly in the UI. The loop NEVER dies on its
/// own — degraded/error keep retrying forever; the states exist so the label
/// stops claiming "Listening…" while nothing could possibly play.
enum ConnState: Equatable {
    case idle
    case listening
    case degraded(String)   // temporarily failing, auto-recovering
    case error(String)      // needs his hands (token/host), still retrying
}

/// Connects to the Mac over Tailscale and pulls voice clips as they're produced.
///
/// Self-healing: each failure discards the connection and rebuilds a fresh one;
/// retries back off but never stop; a watchdog restarts the loop when iOS
/// suspended it in the background; and every state the label shows is real —
/// a 401 is "token mismatch", not "Listening…".
///
/// WALKIE (2026-08-20): against a v2 server the client follows each message's
/// manifest, downloading chunks as the Mac renders them — first audio seconds
/// after the text exists, not after full synthesis. Playback is gated: one
/// chunk, then a pause; Continue advances; the shared "Over" clip marks true
/// end-of-message. Arriving messages QUEUE behind the one playing (the old
/// behavior superseded it mid-audio). A server without /v2 answers 404 and the
/// client falls back to the legacy /next poll unchanged.
@MainActor
final class EchoClient: ObservableObject {
    @Published var state: ConnState = .idle
    @Published var isPlaying = false
    /// True while the mini-player's clip is paused (isPlaying stays true — a
    /// clip is still loaded, just not moving).
    @Published var isPaused = false
    @Published var isListening = false
    /// The clip whose audio is live right now: non-nil only while a message
    /// is actually in flight (playing, gated, or waiting on a render).
    @Published var nowPlayingClip: Clip?
    /// The ACTIVE message — the one the card at the top of the window shows,
    /// full text and controls always visible. Set by every play (tap or
    /// auto-play) and NOT cleared when playback ends: the last open message
    /// stays open. Newest message on launch; its history row gets the border.
    @Published var openClip: Clip?
    @Published var playbackTime: TimeInterval = 0
    @Published var playbackDuration: TimeInterval = 0
    /// Live output level 0…1 while a clip sounds — the speaking orb's breath.
    @Published var audioLevel: Double = 0
    /// Walkie playback position + gates.
    @Published var currentChunk = 0
    @Published var awaitingContinue = false   // paused at a chunk boundary — Continue advances
    @Published var awaitingRender = false     // want the next chunk; the Mac hasn't finished it
    /// Newest-first history of the last 24 hours, persisted across launches.
    /// PERF (2026-08-21): every mutation drops the derived caches below.
    /// `lanes` and `turns(for:)` are O(clips) and were being rebuilt inside
    /// the rail's 24fps animation — the cost grew with every message of the
    /// day, which is exactly the "gets slower until I relaunch" Ranny saw.
    @Published var clips: [Clip] = [] { didSet { invalidateDerived() } }
    /// COCKPIT RAIL (2026-08-21). The lane whose pane fills the window — the
    /// only lane that sounds aloud besides the main orchestrator. nil until
    /// the first message adopts its lane (fresh install = pre-rail behavior).
    @Published private(set) var openLane: String? { didSet { invalidateDerived() } }
    /// The main orchestrator lane, if promoted (A10 "both"): its voice leads
    /// while every other lane queues silently to its pane.
    @Published private(set) var mainLane: String? { didSet { invalidateDerived() } }
    /// Per-lane harness state from the server's /v2/status feed (A9 table:
    /// ready|working|attention|finished|closed). Empty against an old server —
    /// the rail degrades to unplayed-dot rings.
    @Published private(set) var laneStates: [String: LaneStatusEntry] = [:] {
        didSet { invalidateDerived() }
    }

    // MARK: - Derived-state caches (perf)

    /// Rebuilt lazily on first read after any change to clips / lane states /
    /// routing. Reads happen many times per frame (each orb, the ground's
    /// two lookups, the pager's five) — this turns all of them into one.
    private var lanesCache: [LaneInfo]?
    private var turnsCache: [Turn]?
    private var turnsCacheLane: String??

    private func invalidateDerived() {
        lanesCache = nil
        turnsCache = nil
        turnsCacheLane = nil
    }

    let log = EchoLog.shared
    private let store = ClipStore()
    /// Monotonic ticket for play(): lets a finish callback recognize it has
    /// been superseded by a newer play, so it never clears the newer clip's
    /// mini-player state.
    private var playToken = 0
    /// Messages that arrived while one was playing — played in order when the
    /// current one ends. This queue is what replaced play-supersede.
    private var pendingAutoPlay: [UUID] = []
    /// nil = probe /v2 on the next poll; false = server predates v2, poll /next.
    private var v2Available: Bool?
    /// The in-flight walkie message whose manifest we're following.
    private var trackingMsgId: String?
    private var lastStreamProgress = Date()

    init() {
        clips = store.purge(store.load())
        store.save(clips)                    // persist the pruned index too
        openLane = UserDefaults.standard.string(forKey: "openLane") ?? clips.first?.lane
        mainLane = UserDefaults.standard.string(forKey: "mainLane")
        // The window opens on the open lane's latest message.
        openClip = clips.first(where: { $0.lane == openLane }) ?? clips.first
        // Come up listening (2026-08-08). Init-time rather than onAppear so
        // listening never depends on any particular view tree appearing —
        // true for the original menu-bar popover (nothing rendered until
        // clicked) and still right for the windowed app (the window can be
        // closed while the app keeps receiving).
        // Deferred one turn so launch still paints instantly: start() builds the
        // audio and network stacks this class otherwise keeps deliberately lazy.
        // Default true, so a fresh install listens; only an explicit "Stop
        // listening" clears it, and that choice now survives a relaunch.
        // Both platforms since the cockpit phone pass (2026-08-21): the
        // listen toggle left the iPhone UI, so opening the app IS the intent
        // to listen — same as the Mac.
        if UserDefaults.standard.object(forKey: "autoListen") as? Bool ?? true {
            Task { [weak self] in self?.start() }
        }
    }

    // Lazy so launching the app touches neither the audio nor the network stack —
    // both are built only when you actually start listening / play, keeping the
    // first render instant (a slow launch is what makes sideloaded apps blank).
    // ClipPlayer is the platform seam: AVAudioSession ducking on iOS, Core
    // Audio process-tap ducking on macOS.
    private lazy var ducker: ClipPlayer = {
        #if os(iOS)
        let d = AudioDucker()
        #else
        let d = MacDucker()
        #endif
        d.log = { [weak self] msg in self?.log.add("audio: \(msg)") }
        // PERF: these fire ~10x/second and EVERY view observes this object, so
        // an unconditional assign re-laid-out the whole window 20 times a
        // second. Publish only on a change worth a repaint — the scrubber
        // moves in quarter-seconds, the orb breathes in visible steps.
        d.onProgress = { [weak self] time, duration in
            guard let self else { return }
            if abs(time - self.playbackTime) >= 0.25 || self.playbackTime > time {
                self.playbackTime = time
            }
            if self.playbackDuration != duration { self.playbackDuration = duration }
        }
        d.onLevel = { [weak self] level in
            guard let self else { return }
            let v = Double(level)
            if abs(v - self.audioLevel) >= 0.03 || (v == 0 && self.audioLevel != 0) {
                self.audioLevel = v
            }
        }
        return d
    }()
    private var task: Task<Void, Never>?
    /// The /v2/status long-poll loop — separate task, shares the session.
    private var statusTask: Task<Void, Never>?
    private var statusSeq = 0
    private lazy var session = EchoClient.makeSession()
    private var lastPollAt = Date()

    /// A connection-reuse-free session, rebuilt on every error so a half-dead
    /// socket is never retried. iOS waits out brief drops (radio/VPN
    /// transitions on the run); macOS must NOT — the server is loopback, so
    /// "refused" means down, and waitsForConnectivity turned a 1s server
    /// restart into a ~100s deaf spell (connectivity never dropped, so it just
    /// waited). The loop's own backoff+rebuild is the macOS retry path.
    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        #if os(iOS)
        cfg.waitsForConnectivity = true
        #endif
        cfg.timeoutIntervalForRequest = 70
        cfg.timeoutIntervalForResource = 120
        // 3, not 1: the message loop and the status loop each hold a long-poll
        // open — one shared connection would serialize them (a status change
        // would wait out /v2/next's 55s hold before it could even ask). The
        // third slot is the input phase's: a /prompt or /confirm POST must
        // never queue behind the long-polls.
        cfg.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: cfg)
    }

    // Config from UserDefaults (edited in SettingsView / the toggle). The host is
    // sanitized so pasting "http://100.x:8790/nic" still resolves to the bare IP.
    private var host: String {
        var h = (UserDefaults.standard.string(forKey: "macHost") ?? "")
            .trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }   // drop scheme
        h = String(h.split(separator: "/").first ?? "")                    // drop /path
        h = String(h.split(separator: ":").first ?? "")                    // drop :port
        #if os(macOS)
        if h.isEmpty { h = "127.0.0.1" }        // the server runs on this Mac
        #endif
        return h
    }
    private var port: String {
        (UserDefaults.standard.string(forKey: "macPort") ?? "8790")
            .trimmingCharacters(in: .whitespaces)
    }
    private var token: String {
        (UserDefaults.standard.string(forKey: "token") ?? "")
            .trimmingCharacters(in: .whitespaces)
    }
    private var autoPlay: Bool {
        UserDefaults.standard.object(forKey: "autoPlay") == nil
            ? true : UserDefaults.standard.bool(forKey: "autoPlay")
    }
    /// Walkie gating on (default): pause at each chunk boundary and wait for
    /// Continue; "Over" marks the end. Off restores continuous auto-play.
    /// (Mute retired with the input build, 08-21 night: it was auto-play-off
    /// wearing a second hat — the speaker icon now belongs to auto-play.)
    private var walkieMode: Bool {
        UserDefaults.standard.object(forKey: "walkieMode") == nil
            ? true : UserDefaults.standard.bool(forKey: "walkieMode")
    }
    /// Newest walkie message id fully received — the /v2/next cursor. Ids are
    /// the Mac's ms timestamps, so integer order is arrival order.
    private var sinceCursor: Int {
        get { UserDefaults.standard.integer(forKey: "echoSinceMsg") }
        set { UserDefaults.standard.set(newValue, forKey: "echoSinceMsg") }
    }

    var unplayedCount: Int { clips.filter { $0.playedAt == nil }.count }

    // MARK: - Lanes (the stories rail)

    /// The rail's circles: every lane seen in the 24h history plus every lane
    /// the status feed knows (closed lanes only linger while they still have
    /// clips to consult). Main first, then by latest activity.
    var lanes: [LaneInfo] {
        if let c = lanesCache { return c }
        let built = buildLanes()
        lanesCache = built
        return built
    }

    /// The open lane's history as pager TURNS (his prompt + the opening and
    /// final that answered it), grouped by (lane, prompt id); clips without a
    /// turn id page alone. Cached — the pager reads it several times per body.
    func turns(for lane: String?) -> [Turn] {
        if let c = turnsCache, turnsCacheLane == .some(lane) { return c }
        let list: [Clip] = clips.filter { lane == nil || $0.lane == lane }.reversed()
        var built: [Turn] = []
        var at: [String: Int] = [:]
        for c in list {
            if let pid = c.promptId, !pid.isEmpty {
                let key = "\(c.lane)|\(pid)"
                if let i = at[key] {
                    built[i] = Turn(id: key, clips: built[i].clips + [c])
                    continue
                }
                at[key] = built.count
                built.append(Turn(id: key, clips: [c]))
            } else {
                built.append(Turn(id: c.id.uuidString, clips: [c]))
            }
        }
        turnsCache = built
        turnsCacheLane = .some(lane)
        return built
    }

    private func buildLanes() -> [LaneInfo] {
        var activity: [String: Date] = [:]
        var unplayed: [String: Int] = [:]
        for c in clips {
            activity[c.lane] = max(activity[c.lane] ?? .distantPast, c.displayedAt)
            if c.playedAt == nil { unplayed[c.lane, default: 0] += 1 }
        }
        for (lane, st) in laneStates {
            if st.state == "closed" && activity[lane] == nil { continue }
            let d = Date(timeIntervalSince1970: st.ts ?? 0)
            activity[lane] = max(activity[lane] ?? .distantPast, d)
        }
        // Ghosting only makes sense once the feed has spoken: against an old
        // server (empty feed) nothing can be told apart, so nothing ghosts.
        let feedLive = !laneStates.isEmpty
        return activity.keys.map { key in
            let st = laneStates[key]
            return LaneInfo(id: key,
                            name: displayName(for: key),
                            state: st?.state,
                            unplayed: unplayed[key] ?? 0,
                            lastActivity: activity[key] ?? .distantPast,
                            isMain: key == mainLane,
                            isOpen: key == openLane,
                            isGhost: feedLive && (st == nil || st?.state == "closed"))
        }
        .sorted { a, b in
            if a.isMain != b.isMain { return a.isMain }
            if a.isGhost != b.isGhost { return b.isGhost }   // living lanes lead
            return a.lastActivity > b.lastActivity
        }
    }

    /// The lanes allowed to make sound: the open pane plus the main
    /// orchestrator (A10). Everything else queues silently and lights its ring.
    private var soundingLanes: Set<String> {
        var s = Set<String>()
        if let l = openLane { s.insert(l) }
        if let l = mainLane { s.insert(l) }
        return s
    }

    /// Tap on a circle: this lane's pane fills the window — and nothing
    /// sounds (Ranny, orb polish pass): auto-play means "arrivals play while
    /// I'm IN the lane", never "entering a lane starts audio". The backlog
    /// waits as dots; a tap on any paragraph plays it.
    func selectLane(_ lane: String) {
        setOpenLane(lane)
        if let newest = clips.first(where: { $0.lane == lane }) {
            openClip = newest
        }
        probeMode(lane)          // freshen the mode chip for the new pane
    }

    /// Refresh a lane's permission-mode chip: the server reads the pane's own
    /// status line and folds the answer into the status snapshot (the long-
    /// poll delivers it — no response parsing needed here).
    func probeMode(_ lane: String) {
        Task { [weak self] in
            guard let self else { return }
            let enc = lane.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? lane
            _ = try? await self.v2Get("/mode?lane=\(enc)", timeout: 10)
        }
    }

    private func setOpenLane(_ lane: String?) {
        openLane = lane
        UserDefaults.standard.set(lane, forKey: "openLane")
    }

    // MARK: - Lane naming (cockpit iteration close)

    /// Custom names for lane keys, set from the circle's context menu. The
    /// default prettifies the cwd basename (hyphens/underscores → spaces).
    private var laneNames: [String: String] {
        UserDefaults.standard.dictionary(forKey: "laneNames") as? [String: String] ?? [:]
    }

    func displayName(for lane: String) -> String {
        if let n = laneNames[lane], !n.isEmpty { return n }
        let base = lane.isEmpty ? "untagged" : lane
        return base
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    func renameLane(_ lane: String, to newName: String) {
        var m = laneNames
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { m.removeValue(forKey: lane) } else { m[lane] = trimmed }
        UserDefaults.standard.set(m, forKey: "laneNames")
        objectWillChange.send()
        log.add("lane \(lane.isEmpty ? "untagged" : lane) named \"\(trimmed.isEmpty ? "(default)" : trimmed)\"")
    }

    /// Bring a message into the pane without playing it — the pager's
    /// selection when a page switch lands on a message.
    func select(_ clip: Clip) {
        openClip = clips.first(where: { $0.id == clip.id }) ?? clip
    }

    /// Promote (or clear) the main orchestrator. Routing is the app's; the
    /// coordinator ROLE stays the owner file's (One Echo A5: the files remain
    /// the sessions' interchange) — on the Mac we sync it when the lane's
    /// session is known, and the "claim the voice" ritual in that session is
    /// unchanged (the A10 v0 call). Clearing main deliberately leaves the
    /// owner file alone: mailbox routing keeps working for the last coordinator.
    func setMainLane(_ lane: String?) {
        mainLane = lane
        UserDefaults.standard.set(lane, forKey: "mainLane")
        log.add(lane.map { "main orchestrator: \($0)" } ?? "main orchestrator cleared")
        #if os(macOS)
        if let lane, let session = laneStates[lane]?.session, !session.isEmpty {
            let ownerURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/voice/owner")
            try? (session + "\n").write(to: ownerURL, atomically: true, encoding: .utf8)
            log.add("owner file → \(session.prefix(8)) (\(lane))")
        }
        #endif
    }

    /// The app-menu status line (macOS): a dot + one word. No counters — the
    /// rail's dots already carry unheard state (Ranny, cockpit rounding).
    var menuStatus: String {
        guard isListening else { return "⚪️ Idle" }
        switch state {
        case .degraded: return "🟡 Reconnecting…"
        case .error(let why): return "🔴 \(why)"
        default: return isPlaying ? "🟢 Playing…" : "🟢 Listening"
        }
    }

    /// The one line the main screen shows.
    var statusText: String {
        if isPlaying {
            if awaitingContinue { return "Paused at a break — Continue plays the next part" }
            if awaitingRender { return "Waiting for the Mac to render the next part…" }
            return isPaused ? "Paused" : "Playing…"
        }
        switch state {
        case .idle: return "Idle"
        case .listening:
            return unplayedCount == 0 ? "Listening…" : "\(unplayedCount) waiting — tap to play"
        case .degraded(let why): return why
        case .error(let why): return why
        }
    }

    func toggleListening() { isListening ? stop() : start() }

    func start() {
        guard !host.isEmpty, !token.isEmpty else {
            state = .error("Set your Mac host + token in Settings first.")
            return
        }
        guard URL(string: "http://\(host):\(port)/next") != nil else {
            state = .error("Host/port don't form a valid address — check Settings.")
            return
        }
        guard task == nil else { return }        // already listening
        prune()                                  // roll the 24h window before showing the list as live
        isListening = true
        v2Available = nil                        // re-probe: the server may have been upgraded
        // Remember the intent, not the state: only start()/stop() write this,
        // and stop() is reachable only from the user's own toggle — retries and
        // errors never touch it, so a flaky network can't teach the app to come
        // up deaf.
        UserDefaults.standard.set(true, forKey: "autoListen")
        state = .listening
        log.add("listening started → \(host):\(port)")
        // Keep-alive so playback works in the background. If it fails, say so —
        // the old silent print() here was one way "listening" lied. (The result
        // arrives via callback now: session activation runs off-main.)
        ducker.beginListening { [weak self] ok in
            guard let self, !ok, self.isListening else { return }
            self.state = .degraded("Audio keep-alive failed — background playback may stop.")
        }
        task = Task { await loop() }
        statusTask = Task { await statusLoop() }
        if let l = openLane { probeMode(l) }     // best-effort chip warm-up
    }

    func stop() {
        UserDefaults.standard.set(false, forKey: "autoListen")
        task?.cancel()
        task = nil
        statusTask?.cancel()
        statusTask = nil
        session.invalidateAndCancel()
        session = EchoClient.makeSession()
        ducker.endListening()            // stop keep-alive + release the audio session
        isListening = false
        isPlaying = false
        isPaused = false
        nowPlayingClip = nil
        awaitingContinue = false
        awaitingRender = false
        currentChunk = 0
        pendingAutoPlay = []
        trackingMsgId = nil              // /v2/next re-serves anything unfinished on restart
        state = .idle
        log.add("listening stopped")
    }

    /// Called when the app returns to the foreground. If the poll loop hasn't
    /// turned over in well past the long-poll window, iOS suspended or wedged
    /// it while backgrounded — restart it instead of showing a dead "listening".
    func appBecameActive() {
        prune()                // roll the 24h window forward — even when not listening
        guard isListening else { return }
        if let l = openLane { probeMode(l) }     // freshen the mode chip
        let stalled = Date().timeIntervalSince(lastPollAt)
        if stalled > 90 {
            log.add("watchdog: poll loop stalled \(Int(stalled))s — restarting")
            task?.cancel()
            session.invalidateAndCancel()
            session = EchoClient.makeSession()
            task = Task { await loop() }
        }
    }

    private enum Fetch {
        case clip(Clip)
        case empty              // 204 — healthy, nothing queued
        case unauthorized       // 401 — token mismatch
        case unexpected(Int)    // anything else the server shouldn't say
    }

    /// Shape of the Mac's X-Echo-Meta sidecar JSON. Every field optional so a
    /// partial tag still parses.
    private struct ClipMeta: Decodable {
        let lane: String?
        let label: String?
        let ts: Double?
    }

    /// One curated lane link (a dev server, the design canvas…), registered
    /// via echo-link.sh and delivered inside the status snapshot.
    struct LaneLink: Decodable, Equatable {
        let title: String
        let url: String
    }

    /// A permission request waiting on him (input phase): nic-confirm.sh holds
    /// the harness while Echo offers Allow / Deny; a tap answers the hook.
    struct ConfirmInfo: Decodable, Equatable {
        let id: String
        let tool: String
        let summary: String
        let ts: Double?
    }

    /// One lane's entry in the /v2/status snapshot (cockpit rail).
    struct LaneStatusEntry: Decodable, Equatable {
        let state: String       // ready|working|attention|finished|closed
        let session: String?
        let ts: Double?
        let links: [LaneLink]?
        let confirm: ConfirmInfo?
        let mode: String?       // default|acceptEdits|plan|auto|bypassPermissions
    }

    /// The /v2/status long-poll answer: a fold counter + the full snapshot.
    private struct StatusSnapshot: Decodable {
        let seq: Int
        let lanes: [String: LaneStatusEntry]
    }

    /// Shape of a v2 stream manifest (nic-tts.py writes it, echo-server serves
    /// it). Chunk `status` is "pending" | "ready" | "failed".
    private struct Manifest: Decodable {
        struct MChunk: Decodable {
            let seq: Int
            let text: String
            let status: String
            let file: String?
            let dur: Double?
        }
        let id: String
        let lane: String?
        let label: String?
        let ts: Double?
        let text: String
        let chunks: [MChunk]
        let final: Bool
        let role: String?       // "user" = a mirrored prompt (bubble, no audio)
        let prompt: String?     // turn id — groups bubble + opening + final
    }

    private func loop() async {
        var fails = 0
        while !Task.isCancelled {
            lastPollAt = Date()
            do {
                let outcome: Fetch
                if v2Available != false {
                    outcome = try await v2Poll()
                } else {
                    outcome = try await fetchNext()
                }
                switch outcome {
                case .clip(let clip):
                    fails = 0
                    recover()
                    log.add("clip received: \(clip.text.prefix(48))")
                    clips.insert(clip, at: 0)
                    clips = store.purge(clips)
                    store.save(clips)
                    autoPlayArrived(clip)
                case .empty:
                    fails = 0
                    recover()                    // healthy, nothing (new) to play
                    prune()                      // every poll turnover rolls the 24h window
                case .unauthorized:
                    fails += 1
                    if case .error = state {} else {
                        log.add("server says 401 — token mismatch")
                        if isListening { state = .error("Mac rejected the token — check Settings.") }
                    }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                case .unexpected(let code):
                    fails += 1
                    log.add("unexpected HTTP \(code)")
                    if isListening { state = .degraded("Server answered \(code) — retrying…") }
                    try? await Task.sleep(nanoseconds: backoff(fails))
                }
            } catch {
                guard !Task.isCancelled else { return }
                fails += 1
                session.invalidateAndCancel()                    // drop the wedged connection
                session = EchoClient.makeSession()               // and rebuild before retrying
                if fails == 2 {                                  // log the streak once, not every retry
                    log.add("connection failing: \(error.localizedDescription)")
                }
                if isListening && fails >= 2 {
                    state = .degraded("Reconnecting…")
                }
                try? await Task.sleep(nanoseconds: backoff(fails))
            }
        }
    }

    /// Drop clips that crossed the 24h boundary (and their audio files). Runs
    /// on every poll turnover, on foreground, and on start — event-driven but
    /// frequent. Purging only at init was the field-test bug: the app stays
    /// resident for days (keep-alive), so init never re-ran and week-old clips
    /// stayed on the list forever.
    private func prune() {
        let purged = store.purge(clips)
        if purged.count != clips.count {
            clips = purged
            store.save(clips)
            refreshNowPlaying()
        }
    }

    /// Back to "listening" after a bad stretch — and say so in the log.
    private func recover() {
        guard isListening else { return }
        if state != .listening {
            if case .idle = state {} else { log.add("recovered — listening again") }
            state = .listening
        }
    }

    private func backoff(_ fails: Int) -> UInt64 {
        UInt64(min(fails, 5)) * 1_000_000_000                    // 1→5s, capped, never gives up
    }

    // MARK: - v2 walkie polling

    private func v2Get(_ path: String, timeout: TimeInterval = 70) async throws -> (Int, Data) {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(token, forHTTPHeaderField: "X-Echo-Token")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data)
    }

    /// One v2 poll turn: follow the in-flight message's manifest if there is
    /// one, otherwise long-poll for the next message. Detects a pre-v2 server
    /// (404 on /v2/next) and flips the loop to legacy polling.
    private func v2Poll() async throws -> Fetch {
        if let msgId = trackingMsgId {
            guard let clip = clips.first(where: { $0.msgId == msgId }), !clip.isComplete else {
                trackingMsgId = nil
                return .empty
            }
            let have = (clip.chunks ?? []).filter { $0.fileName != nil || $0.failed }.count
            let (status, data) = try await v2Get("/v2/manifest/\(msgId)?have=\(have)")
            switch status {
            case 200:
                if let m = try? JSONDecoder().decode(Manifest.self, from: data) {
                    if await integrate(m) {
                        lastStreamProgress = Date()
                    } else {
                        // The manifest answered but nothing moved (e.g. a chunk
                        // download keeps failing) — don't spin hot, and give up
                        // on the message once it's clearly dead.
                        if Date().timeIntervalSince(lastStreamProgress) > 120 { forceFinal(msgId) }
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
                return .empty
            case 204:
                if Date().timeIntervalSince(lastStreamProgress) > 180 {
                    log.add("stream \(msgId) stalled — closing it out")
                    forceFinal(msgId)
                }
                return .empty
            case 404:
                // Swept before we finished — keep what we have and move on.
                forceFinal(msgId)
                return .empty
            case 401: return .unauthorized
            default: return .unexpected(status)
            }
        }
        let (status, data) = try await v2Get("/v2/next?since=\(sinceCursor)")
        switch status {
        case 200:
            v2Available = true
            guard let m = try? JSONDecoder().decode(Manifest.self, from: data) else {
                return .unexpected(200)
            }
            lastStreamProgress = Date()
            _ = await integrate(m)
            return .empty
        case 204:
            v2Available = true
            await fetchOverIfMissing()      // idle moment: cache the shared Over clip
            return .empty
        case 404:
            if v2Available == nil { log.add("server predates /v2 — legacy polling") }
            v2Available = false
            return .empty
        case 401: return .unauthorized
        default: return .unexpected(status)
        }
    }

    /// Fold a manifest into the history: create the clip on first sight (full
    /// text visible at once), download chunks the Mac has finished, mark the
    /// message complete when everything settled. Returns whether anything moved.
    private func integrate(_ m: Manifest) async -> Bool {
        var progressed = false
        if !clips.contains(where: { $0.msgId == m.id }) {
            var label = m.label ?? ""
            if label.isEmpty { label = Clip.defaultLabel(for: m.text) }
            let isUser = m.role == "user"
            let clip = Clip(id: UUID(), msgId: m.id, text: m.text, lane: m.lane ?? "",
                            label: label, fileName: "",
                            chunks: m.chunks.map { ClipChunk(seq: $0.seq, text: $0.text) },
                            isComplete: false,
                            sentAt: m.ts.map { Date(timeIntervalSince1970: $0) },
                            // A user bubble is born heard — he WROTE it.
                            receivedAt: Date(), playedAt: isUser ? Date() : nil,
                            role: m.role,
                            promptId: (m.prompt?.isEmpty == false) ? m.prompt : nil)
            clips.insert(clip, at: 0)
            progressed = true
            if isUser {
                log.add("prompt bubble (\(clip.lane)): \(m.text.prefix(48))")
                if openLane == nil { setOpenLane(clip.lane) }
                // His own words in the open lane pull the pager to the new
                // turn — the reply will land on the same page.
                if clip.lane == openLane { openClip = clip }
            } else {
                log.add("walkie message \(m.id): \(m.chunks.count) chunks — \(m.text.prefix(48))")
                autoPlayArrived(clip)
            }
        }
        for mc in m.chunks {
            guard let i = clips.firstIndex(where: { $0.msgId == m.id }),
                  let chunks = clips[i].chunks, mc.seq < chunks.count else { break }
            if mc.status == "failed" && !chunks[mc.seq].failed {
                clips[i].chunks?[mc.seq].failed = true
                progressed = true
                chunkSettled(clips[i].id, seq: mc.seq)
            } else if mc.status == "ready" && chunks[mc.seq].fileName == nil {
                do {
                    let (status, data) = try await v2Get("/v2/chunk/\(m.id)/\(mc.seq)", timeout: 30)
                    guard status == 200, !data.isEmpty else { continue }
                    let dest = store.newAudioURL()
                    try data.write(to: dest.url)
                    // Re-find after the await — the array may have shifted.
                    guard let j = clips.firstIndex(where: { $0.msgId == m.id }) else { continue }
                    clips[j].chunks?[mc.seq].fileName = dest.fileName
                    clips[j].chunks?[mc.seq].duration = mc.dur
                    progressed = true
                    chunkSettled(clips[j].id, seq: mc.seq)
                } catch {
                    log.add("chunk \(mc.seq) download failed: \(error.localizedDescription)")
                }
            }
        }
        if let i = clips.firstIndex(where: { $0.msgId == m.id }) {
            let settled = (clips[i].chunks ?? []).allSatisfy { $0.fileName != nil || $0.failed }
            if m.final && settled {
                if !clips[i].isComplete {
                    clips[i].isComplete = true
                    progressed = true
                }
                closeOut(m.id)
            } else {
                trackingMsgId = m.id        // keep following it
            }
        }
        clips = store.purge(clips)
        store.save(clips)
        refreshNowPlaying()
        return progressed
    }

    /// The message is done arriving: advance the /v2/next cursor past it and
    /// stop following its manifest.
    private func closeOut(_ msgId: String) {
        if let n = Int(msgId) { sinceCursor = max(sinceCursor, n) }
        if trackingMsgId == msgId { trackingMsgId = nil }
    }

    /// Close out a message that will never finish (swept, or the Mac died
    /// mid-render): whatever never arrived is marked failed so playback can
    /// walk past it instead of waiting forever.
    private func forceFinal(_ msgId: String) {
        defer { closeOut(msgId) }
        guard let i = clips.firstIndex(where: { $0.msgId == msgId }) else { return }
        if var cs = clips[i].chunks {
            for k in cs.indices where cs[k].fileName == nil { cs[k].failed = true }
            clips[i].chunks = cs
        }
        clips[i].isComplete = true
        store.save(clips)
        refreshNowPlaying()
        if nowPlayingClip?.id == clips[i].id, awaitingRender {
            playChunk(currentChunk)          // skips the failed tail, ends the message
        }
    }

    /// Follow the lane-state feed. 404 = pre-rail server: rings stay dark and
    /// we re-probe lazily (the rest of the rail still works off history lanes).
    /// Errors here never touch the connection state line — the message loop
    /// owns that story; this feed is decoration on top of it.
    private func statusLoop() async {
        var fails = 0
        while !Task.isCancelled {
            do {
                let (code, data) = try await v2Get("/v2/status?since=\(statusSeq)")
                switch code {
                case 200:
                    fails = 0
                    if let snap = try? JSONDecoder().decode(StatusSnapshot.self, from: data) {
                        statusSeq = snap.seq
                        laneStates = snap.lanes
                    }
                case 204:
                    fails = 0
                case 404:
                    try? await Task.sleep(nanoseconds: 120_000_000_000)
                case 401:
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                default:
                    fails += 1
                    try? await Task.sleep(nanoseconds: backoff(fails))
                }
            } catch {
                guard !Task.isCancelled else { return }
                fails += 1
                try? await Task.sleep(nanoseconds: backoff(fails))
            }
        }
    }

    /// Cache the shared end-of-message "Over" clip (rendered once on the Mac).
    private func fetchOverIfMissing() async {
        guard store.overURL() == nil else { return }
        if let (status, data) = try? await v2Get("/v2/over", timeout: 10),
           status == 200, !data.isEmpty {
            store.saveOver(data)
            log.add("cached shared Over clip (\(data.count) bytes)")
        }
    }

    /// Keep the published now-playing / open copies in sync with the history
    /// array — Clip is a value type, so chunk downloads and played marks would
    /// otherwise be invisible to the card. An open clip that fell out of the
    /// 24h window hands the card to the newest message.
    private func refreshNowPlaying() {
        if let id = nowPlayingClip?.id, let c = clips.first(where: { $0.id == id }) {
            nowPlayingClip = c
        }
        if let id = openClip?.id, let c = clips.first(where: { $0.id == id }) {
            openClip = c
        } else if openClip != nil {
            openClip = clips.first(where: { $0.lane == openLane }) ?? clips.first
        }
    }

    private func fetchNext() async throws -> Fetch {
        guard let url = URL(string: "http://\(host):\(port)/next") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 70)      // long-poll window
        req.setValue(token, forHTTPHeaderField: "X-Echo-Token")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 204:
            return .empty
        case 401:
            return .unauthorized
        case 200 where !data.isEmpty:
            // Text is percent-encoded on the Mac so accents/emoji survive the header.
            let raw = http.value(forHTTPHeaderField: "X-Echo-Text") ?? ""
            let text = raw.removingPercentEncoding ?? (raw.isEmpty ? "Voice message" : raw)
            // Tags ride an optional X-Echo-Meta header (percent-encoded JSON:
            // lane / label / ts). Absent or malformed — an old server — falls
            // back cleanly, so both directions stay backward-compatible.
            var lane = "", label = "", sentAt: Date?
            if let rawMeta = http.value(forHTTPHeaderField: "X-Echo-Meta"),
               let json = rawMeta.removingPercentEncoding,
               let meta = try? JSONDecoder().decode(ClipMeta.self, from: Data(json.utf8)) {
                lane = meta.lane ?? ""
                label = meta.label ?? ""
                if let ts = meta.ts { sentAt = Date(timeIntervalSince1970: ts) }
            }
            if label.isEmpty { label = Clip.defaultLabel(for: text) }
            let dest = store.newAudioURL()
            try data.write(to: dest.url)
            return .clip(Clip(id: UUID(), text: text, lane: lane, label: label,
                              fileName: dest.fileName, sentAt: sentAt,
                              receivedAt: Date(), playedAt: nil))
        default:
            return .unexpected(http.statusCode)
        }
    }

    // MARK: - Playback

    /// A message arrived while listening. RAIL GATE first (2026-08-21): only
    /// the open lane and the main orchestrator may sound — anything else sits
    /// silently in its pane and lights its ring (selectLane plays the backlog
    /// when he gets there). Then the walkie rules, unchanged: playing → it
    /// queues (never cuts the current audio); parked silent at a gate → the
    /// new message takes over (the parked one keeps its unplayed dot);
    /// otherwise it plays now. Auto-play off → it just waits in the list.
    private func autoPlayArrived(_ clip: Clip) {
        if openLane == nil {
            setOpenLane(clip.lane)   // first message ever: its lane becomes the pane
        }
        guard autoPlay else { return }
        guard soundingLanes.contains(clip.lane) else {
            log.add("lane \(clip.lane.isEmpty ? "untagged" : clip.lane) queued silently (pane not open)")
            return
        }
        if nowPlayingClip == nil {
            play(clip)
        } else if awaitingContinue {
            log.add("gate interrupted by new message")
            play(clip)
        } else {
            pendingAutoPlay.append(clip.id)
        }
    }

    /// Play a clip now (ducking the music). Used by auto-play, manual taps,
    /// and history replays — a manual tap deliberately supersedes whatever is
    /// playing; automatic arrivals go through autoPlayArrived instead.
    func play(_ clip: Clip) {
        // A direct play cancels any queued auto-play of the same message —
        // otherwise its stale ticket replays it the moment it finishes
        // (the double-reproduction bug, cockpit drive 08-21).
        pendingAutoPlay.removeAll { $0 == clip.id }
        if clip.chunks != nil { startWalkie(clip) } else { playLegacy(clip) }
    }

    /// Legacy single-file clip. Marked played only when it was actually
    /// *heard*: natural completion, or ≥80% elapsed when it ended early
    /// (interruption, stop, replacement) — a call at second 3 of a 30s clip
    /// keeps the dot.
    private func playLegacy(_ clip: Clip) {
        playToken += 1
        let token = playToken
        isPlaying = true
        isPaused = false
        awaitingContinue = false
        awaitingRender = false
        currentChunk = 0
        nowPlayingClip = clip
        openClip = clip
        playbackTime = 0
        playbackDuration = 0
        // The label doubles as the lock-screen Now Playing title.
        ducker.play(url: store.url(for: clip), title: clip.label) { [weak self] fraction in
            guard let self else { return }
            if fraction >= 0.8 { self.markPlayed(clip.id) }
            guard token == self.playToken else { return }   // superseded by a newer play
            self.isPlaying = false
            self.isPaused = false
            self.nowPlayingClip = nil
            self.playNextQueued()
        }
    }

    private func startWalkie(_ clip: Clip) {
        jump(to: 0, in: clip)
    }

    /// Tap-to-play a part: start (or re-enter) this message at chunk `seq` —
    /// tapping a paragraph in the card highlights it and plays from there,
    /// whether the message is idle, finished, or mid-playback. User intent,
    /// so it supersedes whatever is currently sounding; from the tapped part
    /// on, normal walkie flow resumes (gates, then Over at the end).
    func jump(to seq: Int, in clip: Clip) {
        guard let chunks = clip.chunks, seq >= 0, seq < chunks.count else { return }
        pendingAutoPlay.removeAll { $0 == clip.id }   // same replay guard as play()
        playToken += 1
        isPlaying = true
        isPaused = false
        awaitingContinue = false
        awaitingRender = false
        nowPlayingClip = clips.first(where: { $0.id == clip.id }) ?? clip
        openClip = nowPlayingClip
        currentChunk = seq
        playbackTime = 0
        playbackDuration = 0
        Task { await self.fetchOverIfMissing() }   // needed by message end
        playChunk(seq)
    }

    /// Play chunk `index` of the now-playing message, skipping failed ones.
    /// A chunk the Mac hasn't rendered yet parks playback on awaitingRender —
    /// chunkSettled resumes it the moment the download lands.
    private func playChunk(_ index: Int) {
        guard let clip = nowPlayingClip, let chunks = clip.chunks else { return }
        var i = index
        while i < chunks.count, chunks[i].failed { i += 1 }
        currentChunk = min(i, max(chunks.count - 1, 0))
        guard i < chunks.count else { messageAudioDone(); return }
        guard let file = chunks[i].fileName else {
            awaitingRender = true
            awaitingContinue = false
            return
        }
        awaitingRender = false
        awaitingContinue = false
        playToken += 1
        let token = playToken
        isPlaying = true
        isPaused = false
        playbackTime = 0
        playbackDuration = 0
        ducker.play(url: store.url(fileName: file),
                    title: "\(clip.label) — \(i + 1) of \(chunks.count)") { [weak self] _ in
            guard let self, token == self.playToken else { return }
            self.chunkFinished(after: i)
        }
    }

    private func chunkFinished(after index: Int) {
        guard let clip = nowPlayingClip, let chunks = clip.chunks else { return }
        var next = index + 1
        while next < chunks.count, chunks[next].failed { next += 1 }
        guard next < chunks.count else { messageAudioDone(); return }
        if walkieMode {
            // The gate: audio pauses at the chunk boundary (music swells back);
            // Continue plays the next part. currentChunk deliberately STAYS on
            // the finished paragraph so the highlight rests where the voice
            // stopped until Continue is pressed (Ranny, 08-21 eve).
            awaitingContinue = true
            awaitingRender = false
        } else {
            playChunk(next)     // continuous mode: straight through
        }
    }

    /// The gate control — advance past the paragraph the highlight rests on.
    func continueMessage() {
        guard awaitingContinue else { return }
        awaitingContinue = false
        playChunk(currentChunk + 1)      // playChunk itself skips failed chunks
    }

    /// A chunk finished downloading (or failed for good) — feed playback if
    /// it's parked waiting for exactly this.
    private func chunkSettled(_ clipId: UUID, seq: Int) {
        guard nowPlayingClip?.id == clipId else { return }
        refreshNowPlaying()
        if awaitingRender && seq == currentChunk { playChunk(currentChunk) }
    }

    /// Every audible part of the message has played: mark it heard, speak the
    /// shared "Over" (walkie mode), then move to whatever queued behind it.
    private func messageAudioDone() {
        guard let clip = nowPlayingClip else { return }
        markPlayed(clip.id)
        awaitingContinue = false
        awaitingRender = false
        if walkieMode, let over = store.overURL() {
            playToken += 1
            let token = playToken
            ducker.play(url: over, title: "Over") { [weak self] _ in
                guard let self, token == self.playToken else { return }
                self.finishMessage()
            }
        } else {
            finishMessage()
        }
    }

    private func finishMessage() {
        isPlaying = false
        isPaused = false
        nowPlayingClip = nil
        currentChunk = 0
        playNextQueued()
    }

    private func playNextQueued() {
        guard autoPlay else { pendingAutoPlay = []; return }
        while let nextId = pendingAutoPlay.first {
            pendingAutoPlay.removeFirst()
            // A queued item whose lane he switched away from stays as an
            // unplayed dot instead of suddenly sounding from a closed pane.
            if let c = clips.first(where: { $0.id == nextId }),
               soundingLanes.contains(c.lane) {
                play(c)
                return
            }
        }
    }

    // MARK: - Mini-player transport

    /// The user's stop: end the message HERE. Pause keeps the duck engaged
    /// (v0 trade-off), so this is the way to hand the music back mid-message.
    /// The card stays open; whatever queued behind it stays as unplayed dots
    /// rather than suddenly starting.
    func stopPlayback() {
        guard nowPlayingClip != nil else { return }
        // A stop in the last moments still counts as heard (the ≥80% rule).
        if let clip = nowPlayingClip, clip.chunks == nil,
           playbackDuration > 0, playbackTime / playbackDuration >= 0.8 {
            markPlayed(clip.id)
        }
        playToken += 1                   // orphan the in-flight finish callback
        ducker.stopPlayback()
        pendingAutoPlay = []
        isPlaying = false
        isPaused = false
        awaitingContinue = false
        awaitingRender = false
        nowPlayingClip = nil
        currentChunk = 0
        log.add("playback stopped by user")
    }

    func togglePause() {
        guard nowPlayingClip != nil, !awaitingContinue, !awaitingRender else { return }
        if isPaused { ducker.resume() } else { ducker.pause() }
        isPaused.toggle()
    }

    func restartClip() {
        guard nowPlayingClip != nil, !awaitingContinue, !awaitingRender else { return }
        ducker.seek(to: 0)
        playbackTime = 0
    }

    func scrub(to seconds: TimeInterval) {
        guard nowPlayingClip != nil, !awaitingContinue, !awaitingRender else { return }
        ducker.seek(to: seconds)
        playbackTime = seconds
    }

    #if os(macOS)
    /// Forward the Settings "Test duck" to the Mac ducker — the tap-permission
    /// probe (denial is silent, so it measures captured RMS; see MacDucker).
    func testDuck(completion: @escaping (String) -> Void) {
        (ducker as? MacDucker)?.testDuck(completion: completion)
    }
    #endif

    // MARK: - Input (the cockpit speaks back — 2026-08-21 night)

    /// One-line feedback under the input field. Deliberately failure-only:
    /// success needs no announcement — the bubble arriving IS the receipt
    /// (the server mirrors the injected prompt back through the status shim).
    /// Transient (Ranny): it fades on its own after a few seconds.
    @Published var promptFeedback: String?
    private var feedbackToken = 0

    private func flashFeedback(_ msg: String) {
        feedbackToken += 1
        let token = feedbackToken
        promptFeedback = msg
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.feedbackToken == token else { return }
            self.promptFeedback = nil
        }
    }

    /// Type + submit into the open lane's session (server /prompt → herdr).
    func sendPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let lane = openLane else {
            flashFeedback("Open a lane first.")
            return
        }
        promptFeedback = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                let (code, data) = try await self.post(
                    "/prompt", body: ["lane": lane, "text": trimmed])
                if code == 204 {
                    self.log.add("prompt sent → \(self.displayName(for: lane))")
                } else {
                    self.flashFeedback(Self.serverWhy(data)
                        ?? "Send failed (\(code)).")
                    self.log.add("prompt REJECTED (\(code)) — \(self.promptFeedback ?? "")")
                }
            } catch {
                self.flashFeedback("Send failed — \(error.localizedDescription)")
            }
        }
    }

    /// Raw chords into a lane's pane — the mode cycle lives here. The server
    /// allowlists what a "key" can be; free text always goes via sendPrompt.
    func sendKeys(_ keys: [String], lane: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let (code, data) = try await self.post(
                    "/keys", body: ["lane": lane, "keys": keys])
                if code == 204 {
                    self.log.add("keys \(keys.joined(separator: "+")) → \(lane)")
                } else {
                    self.flashFeedback(Self.serverWhy(data) ?? "Keys failed (\(code)).")
                }
            } catch {
                self.flashFeedback("Keys failed — \(error.localizedDescription)")
            }
        }
    }

    /// shift+tab: cycle the lane's permission mode (default → accept edits →
    /// plan → …). The chord needs a terminal window with herdr open (a real
    /// OS keystroke has to land somewhere); the chip converges on ground
    /// truth either way via the follow-up probe.
    func cycleMode(_ lane: String) {
        sendKeys(["shift+tab"], lane: lane)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.probeMode(lane)
        }
    }

    /// Answer a pending permission request (the orange strip's Allow / Deny).
    /// The buttons vanish when the /v2/status snapshot folds the decision.
    func decideConfirm(_ id: String, allow: Bool) {
        Task { [weak self] in
            guard let self else { return }
            _ = try? await self.post(
                "/confirm/decide", body: ["id": id, "decision": allow ? "allow" : "deny"])
            self.log.add("permission \(allow ? "ALLOWED" : "DENIED") (\(id.prefix(12))…)")
        }
    }

    private func post(_ path: String, body: [String: Any]) async throws -> (Int, Data) {
        guard let url = URL(string: "http://\(host):\(port)\(path)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-Echo-Token")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (http.statusCode, data)
    }

    private static func serverWhy(_ data: Data) -> String? {
        (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
    }

    private func markPlayed(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }),
              clips[i].playedAt == nil else { return }
        clips[i].playedAt = Date()
        store.save(clips)
    }
}
