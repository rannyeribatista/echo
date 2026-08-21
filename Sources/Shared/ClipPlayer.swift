import Foundation

/// The seam between EchoClient (pure Foundation, shared) and each platform's
/// audio machinery (design §2): iOS plugs in AudioDucker (AVAudioSession
/// ducking + silent keep-alive), macOS plugs in MacDucker (Core Audio
/// process-tap ducking). Implementations do their work on their own serial
/// queues — never the main thread — and deliver every callback on main.
protocol ClipPlayer: AnyObject {
    /// Diagnostics sink (wired to the on-device log ring).
    var log: (String) -> Void { get set }
    /// Mini-player feed: (currentTime, duration), ~4×/s while a clip is loaded.
    var onProgress: ((TimeInterval, TimeInterval) -> Void)? { get set }
    /// Live output level 0…1 (~10×/s while playing, 0 on finish) — feeds the
    /// speaking orb's breathing on the lane rail.
    var onLevel: ((Float) -> Void)? { get set }

    /// Arm whatever keeps delivery alive while listening (iOS: audio session +
    /// silent loop for the background assertion; macOS: App Nap suppression).
    /// `completion(false)` means delivery is degraded — surface it, don't hide it.
    func beginListening(completion: ((Bool) -> Void)?)
    func endListening()
    /// Duck other audio and play `url`; `onFinish` receives the fraction of
    /// the clip that was heard (1 on natural completion).
    func play(url: URL, title: String, onFinish: ((Double) -> Void)?)
    func pause()
    func resume()
    func seek(to seconds: TimeInterval)
    /// Stop the current clip NOW: release the duck / restore other audio and
    /// report the partial fraction through `onFinish` (pause deliberately
    /// keeps the duck engaged; this is the way out). No-op when idle.
    func stopPlayback()
}
