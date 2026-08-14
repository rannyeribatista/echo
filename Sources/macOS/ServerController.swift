import Foundation

/// Owns the delivery server's lifecycle from the app (fix for the 2026-08-14
/// zombie-audio incident).
///
/// Before this, echo-server.py lived entirely outside the app: started by hand
/// (`echo-send.sh start`), it survived any EchoMac quit and died only at
/// reboot — after which nothing brought it back, while the login agent happily
/// relaunched the *client*. Both halves of the bug follow: with :8790 dead,
/// every announcement takes nic-tts.py's direct fallback (afplay, no ducking,
/// no phone), and quitting EchoMac changes nothing because the voice was never
/// coming from EchoMac.
///
/// The contract now: at launch the app ENSURES the server (starts it when
/// nothing listens on loopback); at quit it stops the server — but only one it
/// started. A server started by hand before the app launched is treated as
/// external and left alone, so phone-only delivery (server up, app quit)
/// remains possible — it just takes an explicit `echo-send.sh start`, which is
/// already how that mode begins. Force-quit skips `applicationWillTerminate`,
/// so a killed app can still leave the server up; `echo-send.sh stop` remains
/// the manual override.
final class ServerController {
    /// Serializes every state touch and script run: an ensure still in flight
    /// when quit arrives finishes first, so stop sees the truth.
    private let queue = DispatchQueue(label: "echo.server-lifecycle")
    /// Queue-confined. True only when *this* app instance started the server.
    private var startedByUs = false

    /// Diagnostics sink (wired to the shared log ring; EchoLog.add is
    /// thread-safe). Defaults to print for tests.
    var log: (String) -> Void = { print("EchoMac: \($0)") }

    /// core/voice's control script unless Settings overrides it
    /// ("serverScript" in UserDefaults). Empty override = default.
    private var script: String {
        let stored = (UserDefaults.standard.string(forKey: "serverScript") ?? "")
            .trimmingCharacters(in: .whitespaces)
        let path = stored.isEmpty ? "~/Projects/core/voice/echo-send.sh" : stored
        return NSString(string: path).expandingTildeInPath
    }

    /// Same port the client polls ("macPort", default 8790). The server always
    /// binds loopback (echo.conf 2026-08-08), so loopback is the probe.
    private var port: UInt16 {
        UInt16(UserDefaults.standard.string(forKey: "macPort") ?? "") ?? 8790
    }

    /// Call at launch: start the server unless something already listens.
    /// Async because `echo-send.sh start` takes ~1s — never on the main thread.
    func ensureRunning() {
        queue.async { [self] in
            guard FileManager.default.isExecutableFile(atPath: script) else {
                log("no server script at \(script) — running as client only")
                return
            }
            if probeLoopback() {
                log("delivery server already on :\(port) (external) — leaving it alone")
                return
            }
            let r = run("start")
            if r.status == 0 && probeLoopback() {
                startedByUs = true
                log("delivery server started on :\(port) — stops when Echo quits")
            } else {
                log("server start failed (exit \(r.status)) — \(r.output.suffix(200))")
            }
        }
    }

    /// Call from applicationWillTerminate. Synchronous on purpose: the process
    /// is about to die, so this is the last chance to run the stop.
    func stopIfOwned() {
        queue.sync { [self] in
            guard startedByUs else { return }
            startedByUs = false
            let r = run("stop")
            log(r.status == 0 ? "delivery server stopped with the app"
                              : "server stop failed (exit \(r.status)) — \(r.output.suffix(200))")
        }
    }

    // MARK: - Plumbing

    /// True when something accepts on 127.0.0.1:port. Loopback connects
    /// resolve immediately (accept or refuse), so a blocking probe is safe.
    private func probeLoopback() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func run(_ verb: String) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script, verb]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return (127, error.localizedDescription)
        }
        // Output is a handful of lines, far under the pipe buffer, so reading
        // after exit can't deadlock.
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
