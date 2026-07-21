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
/// Hard-won iOS rules this file encodes (each was a real bug):
///  - A `.playback` session without `.mixWithOthers` is non-mixable; activating
///    it *pauses* Spotify outright instead of ducking. `.duckOthers` is always
///    paired with `.mixWithOthers` here.
///  - iOS releases a duck on **deactivation**, not on a category change. Merely
///    switching options back to `.mixWithOthers` while active leaves the music
///    dimmed (or paused) forever. Restore = deactivate with
///    `.notifyOthersOnDeactivation`, then re-arm.
///  - Deactivating while any AVAudioPlayer is still playing fails (session
///    busy), so every player is stopped/paused before `setActive(false)`.
///  - The delegate only fires on *natural* completion. Interruptions (call,
///    Siri) end a clip without it, so they're observed and funneled into the
///    same teardown path.
final class AudioDucker: NSObject, AVAudioPlayerDelegate {
    private let session = AVAudioSession.sharedInstance()
    private var keepAlive: AVAudioPlayer?
    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?
    private var listening = false

    /// Diagnostics sink (wired to the on-device log ring). Defaults to print.
    var log: (String) -> Void = { print("Echo: \($0)") }

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
    /// Returns false when the session couldn't be armed — the caller should
    /// surface that (background playback won't work) instead of hiding it.
    @discardableResult
    func beginListening() -> Bool {
        listening = true
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
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
            log("keep-alive failed — \(error.localizedDescription)")
            return false
        }
    }

    func endListening() {
        listening = false
        if player != nil { finishClip(restoringAudio: false) }
        keepAlive?.stop(); keepAlive = nil
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Clip playback (duck → speak → restore)

    /// Duck other audio and play `url`; music restores when the clip ends —
    /// naturally, on error, or on interruption. `title` is what the lock screen
    /// shows while the clip plays.
    func play(url: URL, title: String = "Nic", onFinish: (() -> Void)? = nil) {
        // One clip at a time: a new clip finishes the current one first, so
        // back-to-back plays never stack duck activations.
        if player != nil { finishClip(restoringAudio: false) }

        // Build the player *before* touching the session, so a bad file never
        // ducks the music with nothing to say.
        let p: AVAudioPlayer
        do {
            p = try AVAudioPlayer(contentsOf: url)
        } catch {
            log("unplayable clip — \(error.localizedDescription)")
            onFinish?()
            return
        }
        self.onFinish = onFinish
        player = p
        p.delegate = self
        do {
            try session.setCategory(.playback, mode: .spokenAudio,
                                    options: [.duckOthers, .mixWithOthers])
            // The duck only engages when the session is activated *after* the
            // category change, so always (re)activate — even if already active.
            try session.setActive(true)
        } catch {
            log("duck activation failed — \(error.localizedDescription)")
            // Still try to play; worst case the clip plays un-ducked.
        }
        nowPlaying(title: title, duration: p.duration)
        p.play()
    }

    /// The single teardown path — every way a clip can end funnels here:
    /// natural completion, decode error, interruption, replacement, stop.
    private func finishClip(restoringAudio: Bool = true) {
        player?.stop()
        player = nil
        if restoringAudio { restore() }
        let cb = onFinish
        onFinish = nil
        cb?()
    }

    /// Drop the duck so the music swells back, then re-arm listening. iOS only
    /// releases the duck on deactivation, and deactivation only succeeds once
    /// nothing is playing — hence the pause/deactivate/reactivate dance.
    private func restore() {
        keepAlive?.pause()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            log("restore deactivate failed — \(error.localizedDescription)")
        }
        if listening { rearmListening() }
    }

    private func rearmListening() {
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            keepAlive?.play()
        } catch {
            log("listen re-arm failed — \(error.localizedDescription)")
        }
    }

    // MARK: - Delegate + system events

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, p === self.player else { return }  // ignore the keep-alive loop
            self.finishClip()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, p === self.player else { return }
            self.log("decode error — \(error?.localizedDescription ?? "unknown")")
            self.finishClip()
        }
    }

    @objc private func interrupted(_ note: Notification) {
        let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch type {
            case .began:
                // A call/Siri took the session; iOS already deactivated us and
                // released the duck. Treat the clip as over so onFinish fires
                // and nothing waits on a delegate that will never call.
                self.log("audio interrupted")
                if self.player != nil { self.finishClip(restoringAudio: false) }
            case .ended:
                // Re-arm the keep-alive or the app quietly dies in the
                // background while the UI still says "listening".
                self.log("interruption ended — re-arming")
                if self.listening { self.rearmListening() }
            @unknown default:
                break
            }
        }
    }

    @objc private func mediaReset() {
        // The media daemon crashed: all players are orphaned. Rebuild.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.log("media services reset — rebuilding")
            self.player = nil
            self.keepAlive = nil
            let cb = self.onFinish; self.onFinish = nil; cb?()
            if self.listening { self.beginListening() }
        }
    }

    /// Lock-screen "what's playing" card. With a mixable session another app
    /// (Spotify) may keep ownership of the card — set it anyway; when Echo is
    /// the only audio (screen-off run, no music) it shows the clip label.
    private func nowPlaying(title: String, duration: TimeInterval) {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Nic",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
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
