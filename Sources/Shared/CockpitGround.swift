import SwiftUI

/// The window's ground, shared by both platforms (Ranny: the phone must look
/// the same). Dark mode: near-black at the top; the bottom either settles
/// into gray or — the chosen default — carries a whisper of the featured
/// sphere's status color, gathering at the bottom margin and fading fast
/// upward, tweening with status changes. Light mode keeps the system ground.
struct CockpitGround: View {
    @ObservedObject var client: EchoClient
    @Environment(\.colorScheme) private var scheme
    @AppStorage("darkGround") private var darkGround = "status"

    var body: some View {
        if scheme == .dark {
            if darkGround == "gray" {
                LinearGradient(colors: [Color(white: 0.022), Color(white: 0.055)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(stops: [
                    .init(color: Color(white: 0.022), location: 0),
                    .init(color: Color(white: 0.035), location: 0.68),
                    .init(color: statusTint, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                .animation(.easeInOut(duration: 0.9), value: featuredStateKey)
            }
        } else {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemBackground)
            #endif
        }
    }

    /// The featured lane's status hue, whispered (mirrors the orb palette).
    private var statusTint: Color {
        let lane = client.lanes.first(where: { $0.isOpen })
        let hue: Double
        switch lane?.state {
        case "working": hue = 0.49
        case "attention": hue = 0.08
        case "ready": hue = 0.58
        default: hue = (lane?.unplayed ?? 0) > 0 ? 0.74 : 0.62
        }
        return Color(hue: hue, saturation: 0.45, brightness: 0.14)
    }

    private var featuredStateKey: String {
        let lane = client.lanes.first(where: { $0.isOpen })
        return "\(lane?.state ?? "-")|\((lane?.unplayed ?? 0) > 0)"
    }
}
