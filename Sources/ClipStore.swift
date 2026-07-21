import Foundation

/// Disk half of the 24-hour history: clip audio lives in
/// Application Support/Clips, metadata in clips.json next to it. Dumb on
/// purpose — EchoClient owns the in-memory array; this loads, saves, purges,
/// and hands out file URLs.
struct ClipStore {
    private let dir: URL
    private let index: URL
    private let fm = FileManager.default

    init() {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Clips", isDirectory: true)
        index = base.appendingPathComponent("clips.json")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func url(for clip: Clip) -> URL { dir.appendingPathComponent(clip.fileName) }

    /// A fresh destination for an incoming clip's audio.
    func newAudioURL() -> (fileName: String, url: URL) {
        let name = UUID().uuidString + ".wav"
        return (name, dir.appendingPathComponent(name))
    }

    func load() -> [Clip] {
        guard let data = try? Data(contentsOf: index),
              let clips = try? JSONDecoder().decode([Clip].self, from: data)
        else { return [] }
        return clips
    }

    func save(_ clips: [Clip]) {
        if let data = try? JSONEncoder().encode(clips) {
            try? data.write(to: index, options: .atomic)
        }
    }

    /// 24-hour retention: drop old entries and sweep any audio file no kept
    /// entry references (which also collects strays from crashes).
    func purge(_ clips: [Clip]) -> [Clip] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let keep = clips.filter { $0.receivedAt > cutoff }
        let referenced = Set(keep.map(\.fileName))
        if let files = try? fm.contentsOfDirectory(atPath: dir.path) {
            for f in files where !referenced.contains(f) {
                try? fm.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        return keep
    }
}
