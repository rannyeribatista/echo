import CoreAudio
import Foundation

/// One log row captured on the realtime thread (preallocated, lock-free-ish).
struct RTLogRow {
    var hostTime: UInt64 = 0
    var frames: UInt32 = 0
    var rmsIn: Float = 0
    var gain: Float = 0
}

/// Shared state the realtime callback reads/writes. Word-sized fields; spike-grade
/// (no torn reads possible for aligned 32/64-bit on arm64).
final class RTState {
    var targetGain: Float = 1.0
    var currentGain: Float = 1.0
    var gainStepPerFrame: Float = 0.001   // recomputed from ramp ms + sample rate
    var firstCallbackHost: UInt64 = 0
    var lastCallbackHost: UInt64 = 0
    var callbackCount: UInt64 = 0
    var gapCount: UInt64 = 0              // inter-callback gaps > 1.8x expected
    var maxGapMs: Double = 0
    var expectedIntervalMs: Double = 0
    var writeOutput: Bool = true          // duck mode: true; meter mode: false
    var log: UnsafeMutableBufferPointer<RTLogRow>
    var logIndex: Int = 0

    init(logCapacity: Int) {
        log = UnsafeMutableBufferPointer<RTLogRow>.allocate(capacity: logCapacity)
        log.initialize(repeating: RTLogRow())
    }
    deinit { log.deallocate() }
}

final class TapEngine {
    let state: RTState
    private(set) var tapID: AudioObjectID = 0
    private(set) var aggID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "duckctl.io", qos: .userInteractive)

    // measurements
    var tTapCreateMs: Double = 0
    var tAggCreateMs: Double = 0
    var tIOProcMs: Double = 0
    var tStartMs: Double = 0
    var tapFormat = AudioStreamBasicDescription()

    init(logCapacity: Int = 60_000) {
        state = RTState(logCapacity: logCapacity)
    }

    /// Build tap on `processObjectIDs`, wrap in a private aggregate around the
    /// current default output device, install IO proc, start.
    /// - mute: .mutedWhenTapped for ducking; .unmuted for metering.
    func start(processObjectIDs: [AudioObjectID], globalExcluding: Bool,
               mute: CATapMuteBehavior, writeOutput: Bool) throws {
        state.writeOutput = writeOutput

        let desc: CATapDescription
        if globalExcluding {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: processObjectIDs)
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        }
        desc.muteBehavior = mute
        desc.isPrivate = true
        desc.name = "duckctl-tap"

        var t0 = nowMach()
        var tid = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tid), "AudioHardwareCreateProcessTap")
        tapID = tid
        tTapCreateMs = machToMs(nowMach() - t0)

        tapFormat = try getPOD(tapID, address(kAudioTapPropertyFormat), AudioStreamBasicDescription())

        let out = try defaultOutputDevice()
        let aggUID = UUID().uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "duckctl-agg",
            kAudioAggregateDeviceUIDKey: aggUID,
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
        t0 = nowMach()
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg),
                  "AudioHardwareCreateAggregateDevice")
        aggID = agg
        tAggCreateMs = machToMs(nowMach() - t0)

        // expected callback cadence from device buffer size
        let bufFrames = (try? getPOD(aggID, address(kAudioDevicePropertyBufferFrameSize), UInt32(0))) ?? 0
        let rate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : out.sampleRate
        state.expectedIntervalMs = rate > 0 && bufFrames > 0 ? Double(bufFrames) / rate * 1000 : 10.0

        let st = state
        t0 = nowMach()
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) {
            _, inInputData, _, outOutputData, _ in
            render(state: st, input: inInputData, output: outOutputData)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID
        tIOProcMs = machToMs(nowMach() - t0)

        t0 = nowMach()
        try check(AudioDeviceStart(aggID, ioProcID), "AudioDeviceStart")
        tStartMs = machToMs(nowMach() - t0)
    }

    /// Set duck target gain with a linear ramp of `rampMs`.
    func setGain(_ gain: Float, rampMs: Double) {
        let rate = tapFormat.mSampleRate > 0 ? tapFormat.mSampleRate : 48_000
        let frames = max(1.0, rampMs / 1000.0 * rate)
        state.gainStepPerFrame = abs(gain - state.targetGain) / Float(frames)
        state.targetGain = gain
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

    func waitForFirstCallback(timeoutMs: Double) -> Double? {
        let t0 = nowMach()
        while machToMs(nowMach() - t0) < timeoutMs {
            if state.firstCallbackHost != 0 {
                return machToMs(state.firstCallbackHost - t0)
            }
            usleep(500)
        }
        return nil
    }

    /// Wait until currentGain reached targetGain (ramp done), with timeout.
    func waitForRamp(timeoutMs: Double) {
        let t0 = nowMach()
        while machToMs(nowMach() - t0) < timeoutMs {
            if abs(state.currentGain - state.targetGain) < 0.0005 { return }
            usleep(500)
        }
    }

    func writeCSV(to path: String, t0Host: UInt64) throws {
        var lines = ["t_ms,frames,rms_in,gain"]
        for i in 0..<state.logIndex {
            let r = state.log[i]
            let t = r.hostTime >= t0Host ? machToMs(r.hostTime - t0Host) : -machToMs(t0Host - r.hostTime)
            lines.append(String(format: "%.3f,%u,%.6f,%.4f", t, r.frames, r.rmsIn, r.gain))
        }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// Realtime render: copy tap input -> device output, applying a per-frame gain ramp.
/// Free function to keep the capture list small and allocation-free.
@inline(__always)
func render(state: RTState, input: UnsafePointer<AudioBufferList>,
            output: UnsafeMutablePointer<AudioBufferList>) {
    let now = nowMach()
    if state.firstCallbackHost == 0 { state.firstCallbackHost = now }
    if state.lastCallbackHost != 0 {
        let gapMs = machToMs(now - state.lastCallbackHost)
        if state.expectedIntervalMs > 0 && gapMs > state.expectedIntervalMs * 1.8 {
            state.gapCount += 1
            if gapMs > state.maxGapMs { state.maxGapMs = gapMs }
        }
    }
    state.lastCallbackHost = now
    state.callbackCount += 1

    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outList = UnsafeMutableAudioBufferListPointer(output)

    var sumSquares: Float = 0
    var sampleCount: Int = 0
    var framesInBuffer: UInt32 = 0
    var gain = state.currentGain
    let target = state.targetGain
    let step = state.gainStepPerFrame

    for bufIdx in 0..<inList.count {
        let inBuf = inList[bufIdx]
        guard let inData = inBuf.mData else { continue }
        let channels = max(1, Int(inBuf.mNumberChannels))
        let totalSamples = Int(inBuf.mDataByteSize) / MemoryLayout<Float>.stride
        let frames = totalSamples / channels
        framesInBuffer = max(framesInBuffer, UInt32(frames))
        let inSamples = inData.assumingMemoryBound(to: Float.self)

        var outSamples: UnsafeMutablePointer<Float>? = nil
        var outCapacity = 0
        if state.writeOutput && bufIdx < outList.count, let outData = outList[bufIdx].mData {
            outSamples = outData.assumingMemoryBound(to: Float.self)
            outCapacity = Int(outList[bufIdx].mDataByteSize) / MemoryLayout<Float>.stride
        }

        gain = state.currentGain  // per-buffer resync (buffers advance same frames)
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

    let rms = sampleCount > 0 ? (sumSquares / Float(sampleCount)).squareRoot() : 0
    if state.logIndex < state.log.count {
        state.log[state.logIndex] = RTLogRow(hostTime: now, frames: framesInBuffer,
                                             rmsIn: rms, gain: gain)
        state.logIndex += 1
    }
}
