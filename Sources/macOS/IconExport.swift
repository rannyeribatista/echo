import SwiftUI
import AppKit

/// Icon export (cockpit 2.1): `EchoMac --export-icon <out.png> [--ios]`
/// renders the REAL sphere — the same LaneOrbView the rail draws — frozen at
/// a photogenic phase, amber (the attention palette), on the near-black
/// ground, and exits. Regenerating the icon after any orb evolution is one
/// command; the icon can never drift from the real thing again.
enum IconExporter {
    @MainActor static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--export-icon"), args.count > i + 1 else {
            return false
        }
        let out = URL(fileURLWithPath: args[i + 1])
        let ios = args.contains("--ios")
        var phase = 3.7
        if let pi = args.firstIndex(of: "--phase"), args.count > pi + 1,
           let v = Double(args[pi + 1]) { phase = v }
        let info = LaneInfo(id: "echo", name: "Echo", state: "attention",
                            unplayed: 0, lastActivity: Date(),
                            isMain: false, isOpen: true, isGhost: false)
        let orb = LaneOrbView(info: info, unit: ios ? 9.6 : 8.0, phase: phase,
                              isSpeaking: false, level: 0)
        let bg = LinearGradient(colors: [Color(white: 0.10), Color(white: 0.045)],
                                startPoint: .top, endPoint: .bottom)
        let view: AnyView = ios
            ? AnyView(ZStack { bg; orb }.frame(width: 1024, height: 1024))
            : AnyView(ZStack {
                RoundedRectangle(cornerRadius: 185, style: .continuous)
                    .fill(bg)
                    .frame(width: 824, height: 824)
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                orb
            }.frame(width: 1024, height: 1024))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        if let cg = renderer.cgImage,
           let data = NSBitmapImageRep(cgImage: cg)
               .representation(using: .png, properties: [:]) {
            try? data.write(to: out)
            print("icon written: \(out.path) (\(ios ? "ios" : "mac"))")
        } else {
            print("icon export FAILED")
        }
        return true
    }
}
