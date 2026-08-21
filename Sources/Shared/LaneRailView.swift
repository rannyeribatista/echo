import SwiftUI

/// The stories rail — the window's first element, top to bottom (cockpit sit
/// 2026-08-21): one circle per open lane, Instagram-stories style. The ring
/// carries the lane's harness state (ready / working / attention / finished /
/// closed — the A9 table in docs/cockpit-design.md); the dot marks unheard
/// messages. Tap opens the lane's pane; the context menu promotes a lane to
/// main orchestrator or renames it. Since the iteration close, each circle
/// wears a stable identity gradient derived from its lane key, with initials
/// from the display name — the "profile photo" until real ones exist.
struct LaneInfo: Identifiable {
    let id: String          // lane key ("" = untagged legacy clips)
    let name: String        // display name (custom or prettified basename)
    let state: String?      // ready|working|attention|finished|closed; nil = no status feed
    let unplayed: Int
    let lastActivity: Date
    let isMain: Bool
    let isOpen: Bool
    /// A lane the status feed doesn't know (its session closed before it could
    /// say so, or long ago): still tappable, clearly dead — dashed, dim, last —
    /// and it vanishes with the 24h sweep (Ranny's call, 08-21: ghosts over
    /// hiding, so open-vs-gone stays distinguishable at a glance).
    let isGhost: Bool

    var displayName: String { name }
}

struct LaneRailView: View {
    @ObservedObject var client: EchoClient
    @State private var renamingLane: String?
    @State private var renameText = ""

    var body: some View {
        let lanes = client.lanes
        if !lanes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(lanes) { info in
                        LaneCircle(info: info) {
                            client.selectLane(info.id)
                        } setMain: { on in
                            client.setMainLane(on ? info.id : nil)
                        } rename: {
                            renameText = info.name
                            renamingLane = info.id
                        }
                        .popover(isPresented: Binding(
                            get: { renamingLane == info.id },
                            set: { if !$0 { renamingLane = nil } }
                        )) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Lane name").font(.caption).foregroundStyle(.secondary)
                                TextField(info.id.isEmpty ? "untagged" : info.id,
                                          text: $renameText)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                    .onSubmit {
                                        client.renameLane(info.id, to: renameText)
                                        renamingLane = nil
                                    }
                                Text("Empty restores the default.")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(12)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
    }
}

/// One lane's circle: an identity gradient (stable hash of the lane key) with
/// initials, the status ring around it, the unheard dot, the main star.
struct LaneCircle: View {
    let info: LaneInfo
    let open: () -> Void
    let setMain: (Bool) -> Void
    let rename: () -> Void
    @State private var dim = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        if info.isGhost {
                            Circle()
                                .strokeBorder(Color.gray.opacity(0.45),
                                              style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                                .frame(width: 52, height: 52)
                        } else {
                            Circle()
                                .strokeBorder(ringColor, lineWidth: 3)
                                .opacity(info.state == "working" && dim ? 0.4 : 1)
                                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                           value: dim)
                                .frame(width: 52, height: 52)
                        }
                        Circle()
                            .fill(identityGradient)
                            .frame(width: 42, height: 42)
                            .overlay {
                                Circle().strokeBorder(.white.opacity(info.isOpen ? 0.85 : 0),
                                                      lineWidth: 1.5)
                            }
                            .opacity(info.isGhost ? 0.45 : 1)
                        Text(initials)
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .opacity(info.isGhost ? 0.7 : 1)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if info.isMain {
                            Image(systemName: "star.circle.fill")
                                .font(.system(size: 15))
                                .symbolRenderingMode(.multicolor)
                                .background(Circle().fill(.background))
                        }
                    }
                    if info.unplayed > 0 {
                        Circle().fill(Color.accentColor)
                            .frame(width: 9, height: 9)
                    }
                }
                Text(info.displayName)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 64)
                    .foregroundStyle(info.isOpen ? AnyShapeStyle(.tint)
                                                 : AnyShapeStyle(.secondary))
                    .opacity(info.isGhost ? 0.6 : 1)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename lane…") { rename() }
            // A ghost can't lead the audio — no main toggle on the dead.
            if !info.isGhost {
                if info.isMain {
                    Button("Clear main orchestrator") { setMain(false) }
                } else {
                    Button("Set as main orchestrator") { setMain(true) }
                }
            }
        }
        .help(helpText)
        .onAppear { dim = true }
    }

    /// Two letters of identity: first letters of the first two words of the
    /// display name, else the first two characters.
    private var initials: String {
        let words = info.name.split(separator: " ")
        if words.count >= 2 {
            return (words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(info.name.prefix(2)).uppercased()
    }

    /// A stable per-lane gradient: djb2 over the lane KEY (not the editable
    /// name), so a lane keeps its color across renames and launches.
    private var identityGradient: LinearGradient {
        let h = Self.stableHue(info.id)
        let sat = info.isGhost ? 0.0 : 0.65
        let c1 = Color(hue: h, saturation: sat, brightness: info.isGhost ? 0.6 : 0.78)
        let c2 = Color(hue: (h + 0.08).truncatingRemainder(dividingBy: 1),
                       saturation: info.isGhost ? 0.0 : 0.75,
                       brightness: info.isGhost ? 0.45 : 0.58)
        return LinearGradient(colors: [c1, c2],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static func stableHue(_ s: String) -> Double {
        var h: UInt32 = 5381
        for u in s.unicodeScalars { h = h &* 33 &+ u.value }
        return Double(h % 360) / 360
    }

    /// The A9 colors (design note in docs/cockpit-design.md): teal working,
    /// amber attention, accent for finished-with-unheard, dim for ready/idle.
    /// No status feed (old server) degrades to unplayed-or-dim — rings never lie.
    private var ringColor: Color {
        switch info.state {
        case "working": return .teal
        case "attention": return .orange
        case "ready": return .gray.opacity(0.55)
        case "closed": return .gray.opacity(0.3)
        case "finished": return info.unplayed > 0 ? .accentColor : .gray.opacity(0.5)
        default: return info.unplayed > 0 ? .accentColor : .gray.opacity(0.4)
        }
    }

    private var helpText: String {
        var bits: [String] = [info.name]
        if info.name != info.id, !info.id.isEmpty { bits.append("(\(info.id))") }
        if info.isGhost {
            bits.append("closed — history only")
        } else if let s = info.state {
            bits.append(s)
        }
        if info.unplayed > 0 { bits.append("\(info.unplayed) unheard") }
        if info.isMain { bits.append("main orchestrator") }
        return bits.joined(separator: " · ")
    }
}

/// Lane utils (cockpit iteration close): the open lane's curated links — a
/// dev server, the design canvas, anything external — as tappable chips.
/// Registered from any terminal via echo-link.sh; same chips on the phone.
struct LaneLinksRow: View {
    let links: [EchoClient.LaneLink]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(links, id: \.url) { link in
                    if let url = URL(string: link.url) {
                        Link(destination: url) {
                            Label(link.title, systemImage: "link")
                                .font(.caption)
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .help(link.url)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
