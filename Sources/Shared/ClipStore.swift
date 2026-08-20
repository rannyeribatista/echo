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
    func url(fileName: String) -> URL { dir.appendingPathComponent(fileName) }

    /// A fresh destination for an incoming clip's audio.
    func newAudioURL() -> (fileName: String, url: URL) {
        let name = UUID().uuidString + ".wav"
        return (name, dir.appendingPathComponent(name))
    }

    // The shared end-of-message "Over" clip — rendered once on the Mac,
    // fetched once from /v2/over, kept out of the 24h sweep by name.
    private static let overName = "over.wav"

    func overURL() -> URL? {
        let u = dir.appendingPathComponent(Self.overName)
        return fm.fileExists(atPath: u.path) ? u : nil
    }

    func saveOver(_ data: Data) {
        try? data.write(to: dir.appendingPathComponent(Self.overName), options: .atomic)
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
    /// entry references (which also collects strays from crashes). Walkie
    /// messages reference one file per chunk; the shared Over clip is exempt.
    func purge(_ clips: [Clip]) -> [Clip] {
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let keep = clips.filter { $0.receivedAt > cutoff }
        var referenced = Set(keep.map(\.fileName))
        for clip in keep {
            for chunk in clip.chunks ?? [] {
                if let f = chunk.fileName { referenced.insert(f) }
            }
        }
        referenced.insert(Self.overName)
        if let files = try? fm.contentsOfDirectory(atPath: dir.path) {
            for f in files where !referenced.contains(f) {
                try? fm.removeItem(at: dir.appendingPathComponent(f))
            }
        }
        return keep
    }
}
