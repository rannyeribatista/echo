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
/// Delivery model = open-on-run: while Echo is open and "listening", it holds a
/// long-poll against the Mac (`GET /next`). The Mac answers as soon as it has a
/// clip; otherwise the request times out and we immediately re-ask. No push, no
/// inbound listener on the phone.
///
/// Two modes (the "always-on" toggle):
///   • auto-play ON  → each arrival ducks the music and plays immediately.
///   • auto-play OFF → arrivals queue in `pending`; they play (and duck) on tap.
@MainActor
final class EchoClient: ObservableObject {
    @Published var status = "Idle"
    @Published var isListening = false
    @Published var pending: [Clip] = []

    private let ducker = AudioDucker()
    private var task: Task<Void, Never>?

    // Config lives in UserDefaults, edited in SettingsView / the toggle.
    private var host: String { UserDefaults.standard.string(forKey: "macHost") ?? "" }
    private var port: String { UserDefaults.standard.string(forKey: "macPort") ?? "8790" }
    private var token: String { UserDefaults.standard.string(forKey: "token") ?? "" }
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
        task = Task { await loop() }
    }

    func stop() {
        task?.cancel()
        task = nil
        isListening = false
        status = "Stopped"
    }

    private func loop() async {
        while !Task.isCancelled {
            do {
                if let clip = try await fetchNext() {
                    if autoPlay {
                        play(clip)
                    } else {
                        pending.insert(clip, at: 0)
                        status = "\(pending.count) waiting — tap to play"
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                status = "Reconnecting…"
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func fetchNext() async throws -> Clip? {
        guard let url = URL(string: "http://\(host):\(port)/next") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 65)   // long-poll window
        req.setValue(token, forHTTPHeaderField: "X-Echo-Token")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return nil }
        if http.statusCode == 204 { return nil }              // nothing waiting
        guard http.statusCode == 200, !data.isEmpty else { return nil }

        // Text is percent-encoded on the Mac so accents/emoji survive the header.
        let raw = http.value(forHTTPHeaderField: "X-Echo-Text") ?? ""
        let text = raw.removingPercentEncoding ?? (raw.isEmpty ? "Voice message" : raw)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: tmp)
        if isListening { status = "Listening…" }
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
