import AVFoundation
import MediaPlayer

/// Owns Echo's audio session. Two jobs:
///
///  1. **Keep the app alive in the background while listening.** iOS suspends a
///     backgrounded app unless it's actively producing audio. So while listening
///     we loop a *silent* track through an active session — that holds the
///     `audio` background assertion, so we keep running and the poll loop keeps
///     fetching clips even when the app is backgrounded or the screen is locked.
///  2. **Play each clip by ducking other audio** (Spotify): dim it, speak,
///     restore it — the behavior a plain media player can't do.
///
/// Threading contract (the fix for the 2026-07-25 field-test freeze):
/// `AVAudioSession.setCategory` / `setActive` are **blocking** calls — Apple
/// documents activation as taking up to seconds, and a wedged mediaserverd
/// reply pins the calling thread indefinitely. v1.0 made every one of those
/// calls on the main thread; one stuck deactivation in the clip-end path froze
/// the whole UI forever while the audio threads played on. So now **all
/// session + player state is confined to `queue`** (a private serial queue):
/// every public entry point hops onto it, every delegate/notification funnels
/// into it, and every callback out (`log` / `onProgress` / `onFinish`) hops
/// back to main. The main thread never touches the audio session.
///
/// Hard-won iOS rules this file encodes (each was a real bug):
///  - A `.playback` session without `.mixWithOthers` is non-mixable; activating
///    it *pauses* Spotify outright instead of ducking. `.duckOthers` is always
///    paired with `.mixWithOthers` here.
///  - iOS grants `.duckOthers` **at activation time**. While listening the
///    session is already active (keep-alive), and `setActive(true)` on an
///    already-active session is a silent no-op — so v1.0's "swap options, then
///    re-activate" never engaged the duck and music played over Nic at full
///    volume. Engaging the duck from the listening state requires the full
///    cycle: deactivate → set the duck category → reactivate.
///  - Mode is `.default`, **not** `.spokenAudio`: `.spokenAudio` invites the
///    system to *interrupt* (pause) other spoken audio — podcasts froze
///    instead of dimming. Echo's whole contract is duck, never pause. (Same
///    reason `.interruptSpokenAudioAndMixWithOthers` is not used.)
///  - iOS releases a duck on **deactivation**, not on a category change.
///    Restore = deactivate with `.notifyOthersOnDeactivation`, then re-arm.
///  - Deactivating while any AVAudioPlayer is still playing fails (session
///    busy), so every player is stopped/paused before `setActive(false)`.
///  - The delegate only fires on *natural* completion. Interruptions (call,
///    Siri) end a clip without it, so they're observed and funneled into the
///    same teardown path.
final class AudioDucker: NSObject, AVAudioPlayerDelegate, ClipPlayer {
    private let session = AVAudioSession.sharedInstance()
    /// Confines ALL session/player state below. Session calls block — they
    /// must never run on main (see the threading contract above).
    private let queue = DispatchQueue(label: "echo.audio", qos: .userInitiated)

    // Queue-confined state — touch only on `queue`.
    private var keepAlive: AVAudioPlayer?
    private var player: AVAudioPlayer?
    private var onFinish: ((Double) -> Void)?
    private var listening = false
    private var progressTimer: DispatchSourceTimer?

    /// Diagnostics sink (wired to the on-device log ring); called on main.
    var log: (String) -> Void = { print("Echo: \($0)") }
    /// Mini-player feed: (currentTime, duration), on main, ~4×/s while a clip
    /// is loaded, plus once after every pause/seek so the bar never shows a
    /// stale position.
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?

    override init() {
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(interrupted(_:)),
                       name: AVAudioSession.interruptionNotification, object: session)
        nc.addObserver(self, selector: #selector(mediaReset),
                       name: AVAudioSession.mediaServicesWereResetNotification, object: session)
    }

    // MARK: - Listening (background keep-alive)

    /// Start background-safe listening: activate the session and loop silence so
    /// the app stays running (and fetching) while backgrounded / screen-locked.
    /// `.mixWithOthers` means the silence never interrupts your music.
    /// `completion(false)` (on main) means the session couldn't be armed — the
    /// caller should surface that instead of hiding it.
    func beginListening(completion: ((Bool) -> Void)? = nil) {
        queue.async {
            let ok = self.beginListeningLocked()
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    private func beginListeningLocked() -> Bool {
        listening = true
        do {
            try timed("listen setCategory") {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try timed("listen setActive") { try session.setActive(true) }
            if keepAlive == nil {
                let silent = try AVAudioPlayer(data: Self.silentWav)
                silent.numberOfLoops = -1
                silent.volume = 0
                silent.prepareToPlay()
                keepAlive = silent
            }
            keepAlive?.play()
            return true
        } catch {
            emitLog("keep-alive failed — \(error.localizedDescription)")
            return false
        }
    }

    func endListening() {
        queue.async {
            self.listening = false
            if self.player != nil { self.finishClipLocked(restoringAudio: false) }
            self.keepAlive?.stop(); self.keepAlive = nil
            try? self.session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    // MARK: - Clip playback (duck → speak → restore)

    /// Duck other audio and play `url`; music restores when the clip ends —
    /// naturally, on error, or on interruption. `title` is what the lock screen
    /// shows while the clip plays. `onFinish` receives (on main) the fraction of
    /// the clip that had played when it ended (1 on natural completion) so the
    /// caller can tell "heard" from "cut off at second 3".
    func play(url: URL, title: String = "Nic", onFinish: ((Double) -> Void)? = nil) {
        queue.async { self.playLocked(url: url, title: title, onFinish: onFinish) }
    }

    private func playLocked(url: URL, title: String, onFinish: ((Double) -> Void)?) {
        // One clip at a time: a new clip finishes the current one first, so
        // back-to-back plays never stack duck activations.
        if player != nil { finishClipLocked(restoringAudio: false) }

        // Build the player *before* touching the session, so a bad file never
        // ducks the music with nothing to say.
        let p: AVAudioPlayer
        do {
            p = try AVAudioPlayer(contentsOf: url)
        } catch {
            emitLog("unplayable clip — \(error.localizedDescription)")
            if let onFinish { DispatchQueue.main.async { onFinish(0) } }
            return
        }
        self.onFinish = onFinish
        player = p
        p.delegate = self

        // Engage the duck: deactivate → duck category → reactivate (the only
        // sequence iOS actually honors — see the header). The keep-alive must
        // pause first or the deactivation fails as "session busy".
        keepAlive?.pause()
        do {
            try timed("duck deactivate") { try session.setActive(false) }
        } catch {
            // Session wasn't active (not listening) — fine, activation follows.
        }
        do {
            try timed("duck setCategory") {
                try session.setCategory(.playback, mode: .default,
                                        options: [.duckOthers, .mixWithOthers])
            }
            try timed("duck activate") { try session.setActive(true) }
        } catch {
            emitLog("duck activation failed — \(error.localizedDescription)")
            // Still try to play; worst case the clip plays un-ducked.
        }
        nowPlaying(title: title, duration: p.duration)
        p.play()
        startProgressTimerLocked()
    }

    // MARK: - Transport (mini-player)

    /// Pause the current clip. Deliberate v0 trade-off: the duck stays engaged
    /// while paused (music stays dimmed) — releasing and re-engaging it around
    /// every pause would double the session churn for a rare gesture.
    func pause() {
        queue.async {
            self.player?.pause()
            self.tickProgressLocked()
        }
    }

    func resume() {
        queue.async { self.player?.play() }
    }

    /// Seek within the current clip (0 = back to start). Playing/paused state
    /// is preserved.
    func seek(to seconds: TimeInterval) {
        queue.async {
            guard let p = self.player else { return }
            p.currentTime = max(0, min(seconds, p.duration))
            self.tickProgressLocked()
        }
    }

    func stopPlayback() {
        queue.async {
            guard self.player != nil else { return }
            self.finishClipLocked()      // partial fraction; restores other audio
        }
    }

    private func startProgressTimerLocked() {
        progressTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(250))
        t.setEventHandler { [weak self] in self?.tickProgressLocked() }
        t.resume()
        progressTimer = t
    }

    private func stopProgressTimerLocked() {
        progressTimer?.cancel()
        progressTimer = nil
    }

    private func tickProgressLocked() {
        guard let p = player, let cb = onProgress else { return }
        let time = p.currentTime
        let duration = p.duration
        DispatchQueue.main.async { cb(time, duration) }
    }

    // MARK: - Teardown

    /// The single teardown path — every way a clip can end funnels here:
    /// natural completion, decode error, interruption, replacement, stop.
    /// `completed` is true only on the delegate's natural-completion path
    /// (AVAudioPlayer rewinds `currentTime` to 0 after finishing, so elapsed
    /// time can't tell "played to the end" from "never started"); every other
    /// exit reports how far playback actually got.
    private func finishClipLocked(restoringAudio: Bool = true, completed: Bool = false) {
        stopProgressTimerLocked()
        let fraction: Double
        if completed {
            fraction = 1
        } else if let p = player, p.duration > 0 {
            fraction = min(p.currentTime / p.duration, 1)
        } else {
            fraction = 0
        }
        player?.stop()
        player = nil
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil   // no stale "Nic" card
        }
        if restoringAudio { restoreLocked() }
        let cb = onFinish
        onFinish = nil
        if let cb { DispatchQueue.main.async { cb(fraction) } }
    }

    /// Drop the duck so the music swells back, then re-arm listening. iOS only
    /// releases the duck on deactivation, and deactivation only succeeds once
    /// nothing is playing — hence the pause/deactivate/reactivate dance.
    private func restoreLocked() {
        keepAlive?.pause()
        do {
            try timed("restore deactivate") {
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
            }
        } catch {
            emitLog("restore deactivate failed — \(error.localizedDescription)")
        }
        if listening { rearmListeningLocked() }
    }

    private func rearmListeningLocked() {
        do {
            try timed("re-arm setCategory") {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try timed("re-arm setActive") { try session.setActive(true) }
            keepAlive?.play()
        } catch {
            emitLog("listen re-arm failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Delegate + system events (all funnel onto `queue`)

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        queue.async { [weak self] in
            guard let self, p === self.player else { return }  // ignore the keep-alive loop
            self.finishClipLocked(completed: true)
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        queue.async { [weak self] in
            guard let self, p === self.player else { return }
            self.emitLog("decode error — \(error?.localizedDescription ?? "unknown")")
            self.finishClipLocked()
        }
    }

    @objc private func interrupted(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                // A call/Siri took the session; iOS already deactivated us and
                // released the duck. Treat the clip as over so onFinish fires
                // and nothing waits on a delegate that will never call.
                self.emitLog("audio interrupted")
                if self.player != nil { self.finishClipLocked(restoringAudio: false) }
            case .ended:
                // Re-arm the keep-alive or the app quietly dies in the
                // background while the UI still says "listening".
                self.emitLog("interruption ended — re-arming")
                if self.listening { self.rearmListeningLocked() }
            @unknown default:
                break
            }
        }
    }

    @objc private func mediaReset() {
        // The media daemon crashed: all players are orphaned. Rebuild.
        queue.async { [weak self] in
            guard let self else { return }
            self.emitLog("media services reset — rebuilding")
            self.stopProgressTimerLocked()
            self.player = nil
            self.keepAlive = nil
            let cb = self.onFinish
            self.onFinish = nil
            if let cb { DispatchQueue.main.async { cb(0) } }    // orphaned — elapsed unknowable
            if self.listening { _ = self.beginListeningLocked() }
        }
    }

    // MARK: - Plumbing

    /// Session calls can stall (that's the whole reason `queue` exists). Run
    /// them under a stopwatch so a slow one shows up in the log ring instead
    /// of being invisible — pre-fix, the only symptom was a frozen UI.
    private func timed(_ what: String, _ op: () throws -> Void) rethrows {
        let t0 = DispatchTime.now()
        try op()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        if ms > 250 { emitLog("\(what) took \(Int(ms)) ms") }
    }

    private func emitLog(_ msg: String) {
        DispatchQueue.main.async { self.log(msg) }
    }

    /// Lock-screen "what's playing" card. With a mixable session another app
    /// (Spotify) may keep ownership of the card — set it anyway; when Echo is
    /// the only audio (screen-off run, no music) it shows the clip label.
    /// Cleared in `finishClipLocked` so the card never outlives the clip.
    private func nowPlaying(title: String, duration: TimeInterval) {
        DispatchQueue.main.async {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: title,
                MPMediaItemPropertyArtist: "Nic",
                MPMediaItemPropertyPlaybackDuration: duration,
                MPNowPlayingInfoPropertyPlaybackRate: 1.0,
            ]
        }
    }

    /// A minimal valid silent 16-bit PCM WAV (0.5s @ 8 kHz), built in memory so
    /// there's no bundled asset to ship or lose.
    private static let silentWav: Data = {
        let sampleRate = 8000, channels = 1, bits = 16
        let frames = sampleRate / 2                       // 0.5 s
        let dataBytes = frames * channels * (bits / 8)
        let byteRate = sampleRate * channels * (bits / 8)
        let blockAlign = channels * (bits / 8)
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(36 + dataBytes); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels); u32(sampleRate); u32(byteRate); u16(blockAlign); u16(bits)
        str("data"); u32(dataBytes)
        d.append(Data(count: dataBytes))                  // silence
        return d
    }()
}
