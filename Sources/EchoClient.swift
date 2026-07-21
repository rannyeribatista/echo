import Foundation
import SwiftUI

/// One received voice message. Codable because the last 24 hours of these
/// persist across launches (ClipStore).
struct Clip: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String        // what Nic says (sent by the Mac for display)
    let lane: String        // which session sent it ("core", "studium", "home"…); "" = untagged
    let label: String       // first words of the message — what the row shows
    let fileName: String    // audio file inside ClipStore's directory
    let sentAt: Date?       // when the Mac rendered it (from the tag sidecar)
    let receivedAt: Date
    var playedAt: Date?     // nil = unplayed (the pulsing dot)

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
@MainActor
final class EchoClient: ObservableObject {
    @Published var state: ConnState = .idle
    @Published var isPlaying = false
    @Published var isListening = false
    /// Newest-first history of the last 24 hours, persisted across launches.
    @Published var clips: [Clip] = []

    let log = EchoLog.shared
    private let store = ClipStore()

    init() {
        clips = store.purge(store.load())
    }

    // Lazy so launching the app touches neither the audio nor the network stack —
    // both are built only when you actually start listening / play, keeping the
    // first render instant (a slow launch is what makes sideloaded apps blank).
    private lazy var ducker: AudioDucker = {
        let d = AudioDucker()
        d.log = { [weak self] msg in self?.log.add("audio: \(msg)") }
        return d
    }()
    private var task: Task<Void, Never>?
    private lazy var session = EchoClient.makeSession()
    private var lastPollAt = Date()

    /// A connection-reuse-free session that waits out brief drops. Rebuilt on
    /// every error so a half-dead socket is never retried.
    private static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 70
        cfg.timeoutIntervalForResource = 120
        cfg.httpMaximumConnectionsPerHost = 1
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

    var unplayedCount: Int { clips.filter { $0.playedAt == nil }.count }

    /// The one line the main screen shows.
    var statusText: String {
        if isPlaying { return "Playing…" }
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
        isListening = true
        state = .listening
        log.add("listening started → \(host):\(port)")
        // Keep-alive so playback works in the background. If it fails, say so —
        // the old silent print() here was one way "listening" lied.
        if !ducker.beginListening() {
            state = .degraded("Audio keep-alive failed — background playback may stop.")
        }
        task = Task { await loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
        session = EchoClient.makeSession()
        ducker.endListening()            // stop keep-alive + release the audio session
        isListening = false
        isPlaying = false
        state = .idle
        log.add("listening stopped")
    }

    /// Called when the app returns to the foreground. If the poll loop hasn't
    /// turned over in well past the long-poll window, iOS suspended or wedged
    /// it while backgrounded — restart it instead of showing a dead "listening".
    func appBecameActive() {
        guard isListening else { return }
        clips = store.purge(clips)               // roll the 24h window forward
        store.save(clips)
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

    private func loop() async {
        var fails = 0
        while !Task.isCancelled {
            lastPollAt = Date()
            do {
                switch try await fetchNext() {
                case .clip(let clip):
                    fails = 0
                    recover()
                    log.add("clip received: \(clip.text.prefix(48))")
                    clips.insert(clip, at: 0)
                    clips = store.purge(clips)
                    store.save(clips)
                    if autoPlay { play(clip) }
                case .empty:
                    fails = 0
                    recover()                    // 204 = healthy, nothing to play
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

    /// Play a clip now (ducking the music). Used by auto-play, manual taps,
    /// and history replays. Marked played the moment playback starts — simplest
    /// rule that survives interruptions.
    func play(_ clip: Clip) {
        markPlayed(clip.id)
        isPlaying = true
        ducker.play(url: store.url(for: clip), title: clip.text) { [weak self] in
            self?.isPlaying = false
        }
    }

    private func markPlayed(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }),
              clips[i].playedAt == nil else { return }
        clips[i].playedAt = Date()
        store.save(clips)
    }
}
