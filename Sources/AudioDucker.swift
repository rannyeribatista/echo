import AVFoundation

/// Plays a clip *over* other audio (Spotify, a podcast) by DUCKING it: the other
/// audio is turned down — not paused — for the length of the clip, then restored.
///
/// This is the one behavior a plain media player (VLC) can't do. It comes
/// entirely from how the audio *session* is configured, not from the player:
///   • category `.playback` + option `.duckOthers` → lower everyone else while we speak
///   • mode `.spokenAudio` → tell iOS this is a voice prompt, so it ducks like a nav app
///   • deactivating with `.notifyOthersOnDeactivation` → let the music swell back up
final class AudioDucker: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?
    private let session = AVAudioSession.sharedInstance()

    /// Duck other audio and play the file at `url`. Music restores when it ends.
    func play(url: URL, onFinish: (() -> Void)? = nil) {
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)

            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            self.onFinish = onFinish
            player = p
            p.play()
        } catch {
            // Never leave other apps ducked if we failed to play.
            restoreOthers()
            print("Echo: playback failed — \(error)")
            fireFinish()
        }
    }

    private func restoreOthers() {
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func fireFinish() {
        let cb = onFinish
        onFinish = nil
        cb?()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        restoreOthers()
        fireFinish()
    }
}
