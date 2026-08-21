import AVFoundation
import CoreAudio
import Foundation

/// macOS half of the duck contract (ClipPlayer). iOS gets ducking from
/// AVAudioSession; macOS has no session, so MacDucker *makes* the duck: a
/// Core Audio process tap (TapEngine) takes over the audio path of every app
/// currently producing output — Spotify AND a Chrome YouTube tab — re-renders
/// it at reduced gain while the clip speaks, then hands the path back. That
/// is iOS `.duckOthers` semantics rebuilt, browser audio included
/// (spike-validated 2026-07-21, docs/desktop-design.md).
///
/// Same threading contract as the iOS AudioDucker: all engine/player state is
/// confined to a private serial queue, callbacks out hop to main. The duck
/// ramps (60 ms each way + ~100 ms unity settles) briefly block that queue —
/// by design, never the main thread.
final class MacDucker: NSObject, AVAudioPlayerDelegate, ClipPlayer {
    var log: (String) -> Void = { print("EchoMac: \($0)") }
    var onProgress: ((TimeInterval, TimeInterval) -> Void)?

    private let queue = DispatchQueue(label: "echo.mac-audio", qos: .userInitiated)
    // Queue-confined state — touch only on `queue`.
    private var player: AVAudioPlayer?
    private var onFinish: ((Double) -> Void)?
    private var engine: TapEngine?
    private var engineTargets: Set<AudioObjectID> = []
    private var progressTimer: DispatchSourceTimer?
    private var releaseTimer: DispatchSourceTimer?
    private var engineTeardownTimer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private let scriptDucker = ScriptDucker()

    /// Tap hold (2026-08-21): the audible seams are the PATH HANDOFFS — taking
    /// over the apps' speaker path (a few ms of dropout while the mute lands
    /// before our first write) and handing it back (the re-render runs one IO
    /// cycle late, so release skips those in-flight ms). At unity gain the
    /// passthrough is inaudible, so after a release the tap stays warm this
    /// long: mid-conversation ducks become pure gain ramps (~one IO cycle,
    /// seamless) and the seam pair happens once per burst, not per message.
    private let tapHoldSeconds = 30

    /// Duck hold (2026-08-21): a finished clip does NOT release the duck
    /// immediately — it waits this long, and any new clip inside the window
    /// cancels the release. Kills the flap between continuous-mode paragraphs
    /// (separate streams with a sub-second gap), between the last chunk and
    /// "Over", between queued messages, and on tap-to-play jumps. A user stop
    /// still releases instantly — stop means "music back NOW".
    private let releaseHoldMs = 1000

    /// Residual music level while Nic speaks. 0.2 originally; 0.16 since
    /// 2026-08-20 (Ranny: "duck 20% more"). Tunable without a rebuild:
    /// `defaults write com.rannyeri.echo.mac duckGain -float 0.12`.
    private var duckGain: Float {
        UserDefaults.standard.object(forKey: "duckGain") != nil
            ? UserDefaults.standard.float(forKey: "duckGain") : 0.16
    }
    private let rampMs: Double = 60

    /// "tap" (default) or "applescript" — Settings writes it. The fallback
    /// exists because the tap's System Audio Recording permission can be
    /// denied *silently* (see testDuck); AppleScript at least fails visibly.
    private var duckMode: String {
        UserDefaults.standard.string(forKey: "macDuckMode") ?? "tap"
    }

    // MARK: - ClipPlayer

    func beginListening(completion: ((Bool) -> Void)? = nil) {
        queue.async {
            // No keep-alive needed on macOS. But App Nap throttles hidden
            // menu-bar apps, which can slow the poll loop (design §5 gotcha) —
            // hold an activity assertion while listening.
            if self.activity == nil {
                self.activity = ProcessInfo.processInfo.beginActivity(
                    options: .userInitiatedAllowingIdleSystemSleep,
                    reason: "Echo listens for voice clips")
            }
            if let completion { DispatchQueue.main.async { completion(true) } }
        }
    }

    func endListening() {
        queue.async {
            if self.player != nil { self.finishClipLocked(releaseNow: true) }
            // A pending hold with no new clip coming: let go immediately —
            // listening ended, so the warm tap goes too.
            self.releaseTimer?.cancel()
            self.releaseTimer = nil
            if self.engine != nil {
                self.releaseDuckLocked()
                self.stopEngineLocked(settle: true)
            }
            if let a = self.activity {
                ProcessInfo.processInfo.endActivity(a)
                self.activity = nil
            }
        }
    }

    func play(url: URL, title: String = "Nic", onFinish: ((Double) -> Void)? = nil) {
        queue.async { self.playLocked(url: url, onFinish: onFinish) }
    }

    /// v0 trade-off shared with iOS: the duck stays engaged while paused.
    func pause() {
        queue.async {
            self.player?.pause()
            self.tickProgressLocked()
        }
    }

    func resume() {
        queue.async { self.player?.play() }
    }

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
            self.finishClipLocked(releaseNow: true)   // stop = music back NOW
        }
    }

    // MARK: - Playback

    private func playLocked(url: URL, onFinish: ((Double) -> Void)?) {
        if player != nil { finishClipLocked() }     // one clip at a time
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
        engageDuckLocked()
        p.play()
        startProgressTimerLocked()
    }

    /// Same fraction semantics as iOS: 1 only on natural completion; every
    /// other exit reports how far playback actually got. The duck release is
    /// HELD by default (releaseHoldMs) so back-to-back clips don't flap;
    /// releaseNow is the user-intent escape hatch (stop, end of listening).
    private func finishClipLocked(completed: Bool = false, releaseNow: Bool = false) {
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
        if releaseNow {
            releaseTimer?.cancel()
            releaseTimer = nil
            releaseDuckLocked()
        } else {
            scheduleReleaseLocked()
        }
        let cb = onFinish
        onFinish = nil
        if let cb { DispatchQueue.main.async { cb(fraction) } }
    }

    /// Arm the delayed release. If a new clip starts inside the window,
    /// engageDuckLocked cancels this and the duck never moves.
    private func scheduleReleaseLocked() {
        releaseTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(releaseHoldMs))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.releaseTimer?.cancel()
            self.releaseTimer = nil
            if self.player == nil { self.releaseDuckLocked() }
        }
        t.resume()
        releaseTimer = t
    }

    // MARK: - The duck

    /// Tap everything currently producing output except Echo itself, engage
    /// passthrough at unity, settle, then ramp down (spike quirk #4: both
    /// path-handoff seams happen at identical levels). A silent Mac means no
    /// targets — nothing audible, nothing to duck, the clip just plays.
    private func engageDuckLocked() {
        // A clip arrived inside the release hold: keep the duck exactly where
        // it is — no swell, no re-dip.
        releaseTimer?.cancel()
        releaseTimer = nil
        engineTeardownTimer?.cancel()
        engineTeardownTimer = nil
        if duckMode == "applescript" {
            scriptDucker.duck(to: Double(duckGain))
            return
        }
        do {
            let targets = try listAudioProcesses()
                .filter { $0.isRunningOutput && $0.pid != getpid() }
            guard !targets.isEmpty else { return }   // a warm tap idles at unity; nothing audible to duck
            let ids = Set(targets.map(\.objectID))
            if let e = engine {
                if ids.isSubset(of: engineTargets) {
                    // Warm re-engage: no handoff, just the ramp (~one IO cycle).
                    e.setGain(duckGain, rampMs: rampMs)
                    return
                }
                // Something new is audible (fresh app started mid-hold): the
                // held tap can't duck it. Rebuild — we're at unity, so the
                // handoff seams stay level-matched.
                stopEngineLocked(settle: false)
            }
            let e = TapEngine()
            try e.start(processObjectIDs: targets.map(\.objectID))
            engine = e
            engineTargets = ids
            usleep(100_000)                          // settle the takeover seam at unity
            e.setGain(duckGain, rampMs: rampMs)
            e.waitForRamp(timeoutMs: rampMs + 500)
        } catch {
            engine?.stop()
            engine = nil
            engineTargets = []
            emitLog("duck engage failed — \(error.localizedDescription); playing un-ducked")
        }
    }

    /// Ramp back to unity, then keep the tap WARM (tapHoldSeconds) — the
    /// handoff back to the apps' own path is the audible seam, so it runs
    /// only after a real lull, not between messages.
    private func releaseDuckLocked() {
        if duckMode == "applescript" { scriptDucker.restore() }
        guard let e = engine else { return }
        e.setGain(1.0, rampMs: rampMs)
        e.waitForRamp(timeoutMs: rampMs + 500)
        engineTeardownTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(tapHoldSeconds))
        t.setEventHandler { [weak self] in self?.stopEngineLocked(settle: true) }
        t.resume()
        engineTeardownTimer = t
    }

    /// Actually drop the tap — the apps' own speaker path resumes. Only ever
    /// called at unity gain (release ramped there; rebuilds happen pre-duck).
    private func stopEngineLocked(settle: Bool) {
        engineTeardownTimer?.cancel()
        engineTeardownTimer = nil
        guard let e = engine else { return }
        if settle { usleep(100_000) }
        e.stop()
        engine = nil
        engineTargets = []
    }

    /// Settings' "Test duck": duck whatever is audible for ~2 s and measure
    /// what the tap captured. TCC denial is SILENT — every call returns noErr
    /// and the tap delivers dithered near-silence — so RMS is the only honest
    /// check (spike finding). Also fires the one-time permission prompt while
    /// he's watching, instead of mid-first-message.
    func testDuck(completion: @escaping (String) -> Void) {
        queue.async {
            let verdict: String
            do {
                let targets = try listAudioProcesses()
                    .filter { $0.isRunningOutput && $0.pid != getpid() }
                if targets.isEmpty {
                    verdict = "Nothing is playing audio right now — start some music, then test again."
                } else {
                    let e = TapEngine()
                    try e.start(processObjectIDs: targets.map(\.objectID))
                    usleep(100_000)
                    e.setGain(self.duckGain, rampMs: self.rampMs)
                    Thread.sleep(forTimeInterval: 2)
                    e.setGain(1.0, rampMs: self.rampMs)
                    e.waitForRamp(timeoutMs: self.rampMs + 500)
                    usleep(100_000)
                    let rms = e.averageCapturedRMS
                    e.stop()
                    if rms < 1e-5 {
                        verdict = "Tap captured silence — grant Echo \"System Audio Recording\" in "
                            + "System Settings → Privacy & Security (or switch to the AppleScript duck)."
                    } else {
                        verdict = String(format: "Duck works — captured live audio (RMS %.4f). "
                                         + "You should have heard the dip.", rms)
                    }
                }
            } catch {
                verdict = "Duck failed: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { completion(verdict) }
        }
    }

    // MARK: - Progress

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

    // MARK: - Delegate

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        queue.async { [weak self] in
            guard let self, p === self.player else { return }
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

    private func emitLog(_ msg: String) {
        DispatchQueue.main.async { self.log(msg) }
    }
}
