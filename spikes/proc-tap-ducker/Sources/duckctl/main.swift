import CoreAudio
import Foundation

// duckctl — feasibility spike for per-app ducking via Core Audio process taps.
// Subcommands:
//   list                       processes registered with the audio HAL
//   taps                       tap objects currently alive system-wide
//   duck --app <q> [--gain g] [--seconds s] [--ramp ms] [--csv path]
//   meter [--seconds s] [--csv path]   global-tap RMS meter (no mute, no output)

func usage() -> Never {
    print("""
    usage:
      duckctl list
      duckctl taps
      duckctl duck --app <bundle-id-or-name-substring> [--gain 0.2] [--seconds 5] [--ramp 60] [--csv out.csv]
      duckctl meter [--seconds 10] [--csv out.csv]
    """)
    exit(64)
}

func parseOptions(_ args: [String]) -> [String: String] {
    var opts: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        guard a.hasPrefix("--") else { usage() }
        let key = String(a.dropFirst(2))
        if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
            opts[key] = args[i + 1]; i += 2
        } else {
            opts[key] = "true"; i += 1
        }
    }
    return opts
}

func cmdList() {
    do {
        let procs = try listAudioProcesses()
        print("audio HAL process objects: \(procs.count)")
        print(String(format: "%-8@ %-8@ %-7@ %-7@ %-28@ %@",
                     "objID" as NSString, "pid" as NSString, "out" as NSString,
                     "run" as NSString, "name" as NSString, "bundleID" as NSString))
        for p in procs.sorted(by: { $0.bundleID < $1.bundleID }) {
            print(String(format: "%-8u %-8d %-7@ %-7@ %-28@ %@",
                         p.objectID, p.pid,
                         (p.isRunningOutput ? "YES" : "-") as NSString,
                         (p.isRunning ? "yes" : "-") as NSString,
                         p.name as NSString, p.bundleID as NSString))
        }
    } catch { print("error: \(error)"); exit(1) }
}

func cmdTaps() {
    do {
        let taps = try listTaps()
        print("live tap objects: \(taps.count)")
        for t in taps {
            let uid = (try? getString(t, address(kAudioTapPropertyUID))) ?? "?"
            print("  objID \(t)  uid \(uid)")
        }
    } catch { print("error: \(error)"); exit(1) }
}

func cmdDuck(_ opts: [String: String]) {
    guard let query = opts["app"] else { usage() }
    let gain = Float(opts["gain"] ?? "0.2") ?? 0.2
    let seconds = Double(opts["seconds"] ?? "5") ?? 5
    let rampMs = Double(opts["ramp"] ?? "60") ?? 60
    let csvPath = opts["csv"]

    let t0 = nowMach()
    print("[duck] pid \(getpid())  query '\(query)'  gain \(gain)  hold \(seconds)s  ramp \(Int(rampMs))ms")

    do {
        let procs = try listAudioProcesses()
        let matches = matchProcesses(query: query, in: procs)
        guard !matches.isEmpty else {
            print("[duck] no HAL process object matches '\(query)' — is the app running/registered with audio?")
            exit(2)
        }
        print("[duck] tapping \(matches.count) process object(s):")
        for m in matches {
            print("[duck]   objID \(m.objectID) pid \(m.pid) \(m.name) [\(m.bundleID)] runningOutput=\(m.isRunningOutput)")
        }
        if !matches.contains(where: { $0.isRunningOutput }) {
            print("[duck] warning: none is currently producing output — duck will be a no-op until it plays")
        }

        let engine = TapEngine()
        engine.state.targetGain = 1.0
        engine.state.currentGain = 1.0
        try engine.start(processObjectIDs: matches.map(\.objectID),
                         globalExcluding: false,
                         mute: .mutedWhenTapped, writeOutput: true)
        let fmt = engine.tapFormat
        print(String(format: "[duck] tap format: %.0f Hz, %u ch, flags 0x%x, %u bytes/frame",
                     fmt.mSampleRate, fmt.mChannelsPerFrame, fmt.mFormatFlags, fmt.mBytesPerFrame))
        print(String(format: "[duck] t+%.1f ms  tap created (%.1f ms) | aggregate (%.1f ms) | ioproc (%.1f ms) | start (%.1f ms)",
                     machToMs(nowMach() - t0), engine.tTapCreateMs, engine.tAggCreateMs,
                     engine.tIOProcMs, engine.tStartMs))

        guard engine.waitForFirstCallback(timeoutMs: 3000) != nil else {
            print("[duck] FAIL: no IO callback within 3 s — tap/aggregate not delivering")
            engine.stop(); exit(3)
        }
        let firstCbMs = machToMs(engine.state.firstCallbackHost - t0)
        print(String(format: "[duck] t+%.1f ms  first IO callback — mute-on-read engages here; passthrough at unity gain", firstCbMs))

        // small unity-gain settle so the takeover seam and the duck ramp are separable
        usleep(150_000)

        let rampStart = nowMach()
        engine.setGain(gain, rampMs: rampMs)
        engine.waitForRamp(timeoutMs: rampMs + 500)
        print(String(format: "[duck] t+%.1f ms  DUCKED to %.2f (ramp took %.1f ms)",
                     machToMs(nowMach() - t0), gain, machToMs(nowMach() - rampStart)))

        Thread.sleep(forTimeInterval: seconds)

        let releaseStart = nowMach()
        engine.setGain(1.0, rampMs: rampMs)
        engine.waitForRamp(timeoutMs: rampMs + 500)
        let rampBackMs = machToMs(nowMach() - releaseStart)
        usleep(100_000) // settle at unity before dropping the tap (seam back at full volume)
        let tearStart = nowMach()
        engine.stop()
        let tearMs = machToMs(nowMach() - tearStart)
        print(String(format: "[duck] t+%.1f ms  released (ramp %.1f ms) + teardown %.1f ms — app back on its own path",
                     machToMs(nowMach() - t0), rampBackMs, tearMs))

        // stats
        let st = engine.state
        let rows = (0..<st.logIndex).map { st.log[$0] }
        let silent = rows.filter { $0.rmsIn < 1e-7 }.count
        let avgRMS = rows.isEmpty ? 0 : rows.map(\.rmsIn).reduce(0, +) / Float(rows.count)
        print(String(format: "[duck] callbacks %llu | cadence %.1f ms | gaps(>1.8x) %llu | max gap %.1f ms",
                     st.callbackCount, st.expectedIntervalMs, st.gapCount, st.maxGapMs))
        print(String(format: "[duck] captured input: avg RMS %.5f | silent callbacks %d/%d %@",
                     avgRMS, silent, rows.count,
                     (avgRMS < 1e-6 ? "(ALL SILENT — likely TCC denial or app not playing)" : "") as NSString))
        if let path = csvPath {
            try engine.writeCSV(to: path, t0Host: t0)
            print("[duck] per-callback CSV -> \(path)")
        }
    } catch {
        print("[duck] error: \(error)")
        exit(1)
    }
}

func cmdMeter(_ opts: [String: String]) {
    let seconds = Double(opts["seconds"] ?? "10") ?? 10
    let csvPath = opts["csv"]
    let t0 = nowMach()
    print("[meter] pid \(getpid()) global tap (unmuted, listen-only) for \(seconds)s")
    do {
        let engine = TapEngine(logCapacity: 200_000)
        try engine.start(processObjectIDs: [], globalExcluding: true,
                         mute: .unmuted, writeOutput: false)
        guard engine.waitForFirstCallback(timeoutMs: 3000) != nil else {
            print("[meter] FAIL: no IO callback within 3 s")
            engine.stop(); exit(3)
        }
        print(String(format: "[meter] first callback at t+%.1f ms; printing RMS every 250 ms",
                     machToMs(engine.state.firstCallbackHost - t0)))
        let st = engine.state
        var lastPrinted = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            Thread.sleep(forTimeInterval: 0.25)
            let count = st.logIndex
            if count > lastPrinted {
                let slice = (lastPrinted..<count).map { st.log[$0].rmsIn }
                let avg = slice.reduce(0, +) / Float(slice.count)
                print(String(format: "[meter] t+%7.0f ms  rms %.5f", machToMs(nowMach() - t0), avg))
                lastPrinted = count
            }
        }
        engine.stop()
        if let path = csvPath {
            try engine.writeCSV(to: path, t0Host: t0)
            print("[meter] per-callback CSV -> \(path)")
        }
    } catch {
        print("[meter] error: \(error)")
        exit(1)
    }
}

// MARK: - entry

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else { usage() }
let opts = parseOptions(Array(argv.dropFirst()))
switch cmd {
case "list": cmdList()
case "taps": cmdTaps()
case "duck": cmdDuck(opts)
case "meter": cmdMeter(opts)
default: usage()
}
