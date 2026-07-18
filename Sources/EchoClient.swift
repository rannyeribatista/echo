import Foundation
import SwiftUI

/// One received voice message.
struct Clip: Identifiable {
    let id = UUID()
    let text: String        // what Nic says (sent by the Mac for display)
    let fileURL: URL        // the downloaded audio, in a temp file
    let receivedAt: Date
}

/// Connects to the Mac over Tailscale and pulls voice clips as they're produced.
///
/// Self-healing: a brief network blip (using the phone, switching apps, a Wi-Fi
/// hiccup) no longer wedges it. Each failure discards the connection and rebuilds
/// a fresh one; the session waits out short connectivity gaps instead of failing;
/// and the status only shows "Reconnecting…" after repeated failures, snapping
/// back to "Listening…" the moment a request succeeds — no manual restart needed.
@MainActor
final class EchoClient: ObservableObject {
    @Published var status = "Idle"
    @Published var isListening = false
    @Published var pending: [Clip] = []

    // Lazy so launching the app touches neither the audio nor the network stack —
    // both are built only when you actually start listening / play, keeping the
    // first render instant (a slow launch is what makes sideloaded apps blank).
    private lazy var ducker = AudioDucker()
    private var task: Task<Void, Never>?
    private lazy var session = EchoClient.makeSession()

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

    func toggleListening() { isListening ? stop() : start() }

    func start() {
        guard !host.isEmpty, !token.isEmpty else {
            status = "Set your Mac host + token in Settings first."
            return
        }
        isListening = true
        status = "Listening…"
        ducker.beginListening()          // keep-alive so playback works in the background
        task = Task { await loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
        session = EchoClient.makeSession()
        ducker.endListening()            // stop keep-alive + release the audio session
        isListening = false
        status = "Stopped"
    }

    private func loop() async {
        var fails = 0
        while !Task.isCancelled {
            do {
                if let clip = try await fetchNext() {
                    fails = 0
                    if autoPlay {
                        play(clip)
                    } else {
                        pending.insert(clip, at: 0)
                        status = "\(pending.count) waiting — tap to play"
                    }
                } else {
                    fails = 0                                    // 204 = healthy, nothing to play
                    if isListening && pending.isEmpty { status = "Listening…" }
                }
            } catch {
                guard !Task.isCancelled else { return }
                fails += 1
                session.invalidateAndCancel()                    // drop the wedged connection
                session = EchoClient.makeSession()               // and rebuild before retrying
                if isListening {
                    status = fails >= 2 ? "Reconnecting…" : "Listening…"
                }
                let backoff = UInt64(min(fails, 5)) * 1_000_000_000   // 1→5s, capped
                try? await Task.sleep(nanoseconds: backoff)
            }
        }
    }

    private func fetchNext() async throws -> Clip? {
        guard let url = URL(string: "http://\(host):\(port)/next") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 70)      // long-poll window
        req.setValue(token, forHTTPHeaderField: "X-Echo-Token")

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 204 { return nil }                // nothing waiting
        guard http.statusCode == 200, !data.isEmpty else { return nil }

        // Text is percent-encoded on the Mac so accents/emoji survive the header.
        let raw = http.value(forHTTPHeaderField: "X-Echo-Text") ?? ""
        let text = raw.removingPercentEncoding ?? (raw.isEmpty ? "Voice message" : raw)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: tmp)
        return Clip(text: text, fileURL: tmp, receivedAt: Date())
    }

    /// Play a clip now (ducking the music). Used by auto-play and by manual taps.
    func play(_ clip: Clip) {
        status = "Playing…"
        ducker.play(url: clip.fileURL) { [weak self] in
            guard let self else { return }
            self.pending.removeAll { $0.id == clip.id }
            self.status = self.isListening ? "Listening…" : "Idle"
        }
    }
}
