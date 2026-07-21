import Foundation

/// A tiny on-device diagnostic ring: the last 200 notable events (state
/// changes, clips, failures — never per-poll noise), visible in Settings and
/// persisted across launches, so the next "it didn't play" is answerable from
/// the phone instead of guesswork.
final class EchoLog: ObservableObject {
    static let shared = EchoLog()
    @Published private(set) var lines: [String] = []
    private let cap = 200
    private let file: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("echo-log.txt")
        if let saved = try? String(contentsOf: file, encoding: .utf8) {
            lines = Array(saved.split(separator: "\n").map(String.init).suffix(cap))
        }
    }

    func add(_ msg: String) {
        let line = "\(Self.stamp.string(from: Date()))  \(msg)"
        if Thread.isMainThread { append(line) }
        else { DispatchQueue.main.async { self.append(line) } }
    }

    func clear() {
        lines = []
        try? FileManager.default.removeItem(at: file)
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > cap { lines.removeFirst(lines.count - cap) }
        // The volume is low (events, not polls), so a straight rewrite is fine.
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()
}
