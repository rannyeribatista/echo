import SwiftUI

/// The stories rail — the window's first element, top to bottom (cockpit sit
/// 2026-08-21): one circle per open lane, Instagram-stories style. The ring
/// carries the lane's harness state (ready / working / attention / finished /
/// closed — the A9 table in docs/cockpit-design.md); the dot marks unheard
/// messages. Tap opens the lane's pane; the context menu promotes a lane to
/// main orchestrator — its voice leads while every other lane queues silently
/// (A10 "both"). Shared view: the iPhone renders the same rail.
struct LaneInfo: Identifiable {
    let id: String          // lane key ("" = untagged legacy clips)
    let state: String?      // ready|working|attention|finished|closed; nil = no status feed
    let unplayed: Int
    let lastActivity: Date
    let isMain: Bool
    let isOpen: Bool

    var displayName: String { id.isEmpty ? "untagged" : id }
}

struct LaneRailView: View {
    @ObservedObject var client: EchoClient

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
                        }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
        }
    }
}

/// One lane's circle. Ring color is state; a working ring pulses (the same
/// heartbeat idiom as the unplayed dot); the open lane's circle is tinted;
/// the main orchestrator wears a star.
struct LaneCircle: View {
    let info: LaneInfo
    let open: () -> Void
    let setMain: (Bool) -> Void
    @State private var dim = false

    var body: some View {
        Button(action: open) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        Circle()
                            .strokeBorder(ringColor, lineWidth: 3)
                            .opacity(info.state == "working" && dim ? 0.4 : 1)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                       value: dim)
                            .frame(width: 52, height: 52)
                        Circle()
                            .fill(info.isOpen ? Color.accentColor.opacity(0.18)
                                              : Color.primary.opacity(0.06))
                            .frame(width: 42, height: 42)
                        Text(initials)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(info.isOpen ? AnyShapeStyle(.tint)
                                                         : AnyShapeStyle(.primary))
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
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if info.isMain {
                Button("Clear main orchestrator") { setMain(false) }
            } else {
                Button("Set as main orchestrator") { setMain(true) }
            }
        }
        .help(helpText)
        .onAppear { dim = true }
    }

    private var initials: String { String(info.displayName.prefix(2)).uppercased() }

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
        var bits: [String] = [info.displayName]
        if let s = info.state { bits.append(s) }
        if info.unplayed > 0 { bits.append("\(info.unplayed) unheard") }
        if info.isMain { bits.append("main orchestrator") }
        return bits.joined(separator: " · ")
    }
}
