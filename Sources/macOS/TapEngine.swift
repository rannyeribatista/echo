import CoreAudio
import Foundation

/// State shared with the realtime IO callback. Word-sized fields only —
/// aligned 32/64-bit loads/stores don't tear on arm64. Deliberately lock-free
/// (spike-validated contract): the render path must never block.
final class RTState {
    var targetGain: Float = 1.0
    var currentGain: Float = 1.0
    var gainStepPerFrame: Float = 0.001   // recomputed from ramp ms + sample rate
    var writeOutput: Bool = true
    var callbackCount: UInt64 = 0
    var rmsSum: Float = 0                 // running sum of per-callback input RMS
}

/// The ducking engine, ported from the validated spike (duckctl): tap the
/// target apps' HAL process objects with `.mutedWhenTapped`, wrap tap + the
/// default output device in a *private* aggregate device, and run an IOProc
/// that re-renders the tapped audio to the output at `currentGain`. While the
/// tap is read, macOS silences the apps' own path — the IOProc IS their
/// speaker path, at whatever gain we choose; stop reading and their own path
/// resumes. Duck = ramp 1.0→gain; release = ramp back, then tear down.
///
/// Spike-measured: ~15-60 ms create-to-first-callback (engage well under
/// 0.5 s cold), 0 callback gaps, ~0.1% CPU, and no stuck mute if the process
/// dies mid-duck (the HAL destroys a dead client's tap).
final class TapEngine {
    let state = RTState()
    private(set) var tapID: AudioObjectID = 0
    private(set) var aggID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "echo.tap-io", qos: .userInteractive)
    private var tapFormat = AudioStreamBasicDescription()

    /// Mean captured input RMS across all callbacks — the silent-denial probe.
    /// A TCC-denied tap runs perfectly and hears dithered near-silence
    /// (~1e-4 RMS at -80 dB); audible music measures orders of magnitude more.
    var averageCapturedRMS: Float {
        state.callbackCount > 0 ? state.rmsSum / Float(state.callbackCount) : 0
    }

    /// Build the tap on `processObjectIDs`, aggregate it with the current
    /// default output device, install the IOProc, start. Starts at unity gain
    /// (passthrough) — sequence both handoff seams at 1.0 (spike quirk #4).
    func start(processObjectIDs: [AudioObjectID]) throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        desc.muteBehavior = .mutedWhenTapped
        desc.isPrivate = true
        desc.name = "echo-duck-tap"

        var tid = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tid), "AudioHardwareCreateProcessTap")
        tapID = tid
        tapFormat = try getPOD(tapID, address(kAudioTapPropertyFormat), AudioStreamBasicDescription())

        let out = try defaultOutputDevice()
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "echo-duck-agg",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: out.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: out.uid]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: desc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg),
                  "AudioHardwareCreateAggregateDevice")
        aggID = agg

        // Shrink the IO cycle (default 512 frames ≈ 10.7 ms → 128 ≈ 2.7 ms).
        // The audible seams — the engage dropout and the release-time jump —
        // are one IO cycle wide, so this pushes them under perception.
        // Best-effort: a device that refuses keeps its default and everything
        // still works, just with the old seam width. CPU impact ~nil (spike
        // measured 0.0-0.1% at 512).
        var ioFrames: UInt32 = 128
        var bufAddr = address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(aggID, &bufAddr, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &ioFrames)

        let st = state
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) {
            _, inInputData, _, outOutputData, _ in
            render(state: st, input: inInputData, output: outOutputData)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID

        try check(AudioDeviceStart(aggID, ioProcID), "AudioDeviceStart")
    }

    /// Set the duck target with a linear ramp of `rampMs`. The ramp is applied
    /// per-frame on the render thread; a silent target produces no callbacks
    /// (spike quirk #1), so don't gate on convergence — when its audio starts,
    /// it ramps then.
    func setGain(_ gain: Float, rampMs: Double) {
        let rate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : 48_000
        let frames = max(1.0, rampMs / 1000.0 * rate)
        state.gainStepPerFrame = abs(gain - state.targetGain) / Float(frames)
        state.targetGain = gain
    }

    /// Wait (bounded) for the ramp to converge — used to hold the handoff
    /// seams at unity. Times out harmlessly when the target is silent.
    func waitForRamp(timeoutMs: Double) {
        let deadline = Date().addingTimeInterval(timeoutMs / 1000)
        while Date() < deadline {
            if abs(state.currentGain - state.targetGain) < 0.0005 { return }
            usleep(500)
        }
    }

    func stop() {
        if let p = ioProcID, aggID != 0 {
            AudioDeviceStop(aggID, p)
            AudioDeviceDestroyIOProcID(aggID, p)
            ioProcID = nil
        }
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
    }

    deinit { stop() }
}

/// Realtime render: copy tap input → device output, applying the per-frame
/// gain ramp. Free function, allocation-free — this runs on the audio thread.
@inline(__always)
private func render(state: RTState, input: UnsafePointer<AudioBufferList>,
                    output: UnsafeMutablePointer<AudioBufferList>) {
    state.callbackCount += 1
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outList = UnsafeMutableAudioBufferListPointer(output)

    var sumSquares: Float = 0
    var sampleCount = 0
    var gain = state.currentGain
    let target = state.targetGain
    let step = state.gainStepPerFrame

    for bufIdx in 0..<inList.count {
        let inBuf = inList[bufIdx]
        guard let inData = inBuf.mData else { continue }
        let channels = max(1, Int(inBuf.mNumberChannels))
        let totalSamples = Int(inBuf.mDataByteSize) / MemoryLayout<Float>.stride
        let frames = totalSamples / channels
        let inSamples = inData.assumingMemoryBound(to: Float.self)

        var outSamples: UnsafeMutablePointer<Float>? = nil
        var outCapacity = 0
        if state.writeOutput && bufIdx < outList.count, let outData = outList[bufIdx].mData {
            outSamples = outData.assumingMemoryBound(to: Float.self)
            outCapacity = Int(outList[bufIdx].mDataByteSize) / MemoryLayout<Float>.stride
        }

        gain = state.currentGain  // per-buffer resync (buffers advance the same frames)
        for f in 0..<frames {
            if gain != target {
                if abs(target - gain) <= step { gain = target }
                else { gain += (target > gain) ? step : -step }
            }
            for c in 0..<channels {
                let idx = f * channels + c
                let s = inSamples[idx]
                sumSquares += s * s
                if let outP = outSamples, idx < outCapacity {
                    outP[idx] = s * gain
                }
            }
        }
        sampleCount += totalSamples
    }
    state.currentGain = gain
    if sampleCount > 0 {
        state.rmsSum += (sumSquares / Float(sampleCount)).squareRoot()
    }
}
