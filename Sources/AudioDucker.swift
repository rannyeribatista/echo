import AVFoundation

/// Owns Echo's audio session. Two jobs:
///
///  1. **Keep the app alive in the background while listening.** iOS suspends a
///     backgrounded app unless it's actively producing audio. So while listening
///     we loop a *silent* track through an active session — that holds the
///     `audio` background assertion, so we keep running and the poll loop keeps
///     fetching clips even when the app is backgrounded or the screen is locked.
///  2. **Play each clip by ducking other audio** (Spotify): dim it, speak,
///     restore it — the behavior a plain media player can't do.
final class AudioDucker: NSObject, AVAudioPlayerDelegate {
    private let session = AVAudioSession.sharedInstance()
    private var keepAlive: AVAudioPlayer?
    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?
    private var listening = false

    /// Start background-safe listening: activate the session and loop silence so
    /// the app stays running (and fetching) while backgrounded / screen-locked.
    /// `.mixWithOthers` means the silence never interrupts your music.
    func beginListening() {
        listening = true
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let silent = try AVAudioPlayer(data: Self.silentWav)
            silent.numberOfLoops = -1
            silent.volume = 0
            silent.prepareToPlay()
            silent.play()
            keepAlive = silent
        } catch {
            print("Echo: keep-alive failed — \(error)")
        }
    }

    func endListening() {
        listening = false
        keepAlive?.stop(); keepAlive = nil
        player?.stop(); player = nil
        onFinish = nil
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Duck other audio and play `url`; music restores when it ends. Works in the
    /// background because beginListening() already activated the session.
    func play(url: URL, onFinish: (() -> Void)? = nil) {
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            if !listening { try session.setActive(true) }
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            self.onFinish = onFinish
            player = p
            p.play()
        } catch {
            restore()
            print("Echo: playback failed — \(error)")
            fireFinish()
        }
    }

    /// After a clip: drop the duck so the music swells back. Stay active if still
    /// listening (keep-alive continues); otherwise release the session.
    private func restore() {
        if listening {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } else {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }   // ignore the silent keep-alive loop
        self.player = nil
        restore()
        fireFinish()
    }

    private func fireFinish() {
        let cb = onFinish
        onFinish = nil
        cb?()
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
