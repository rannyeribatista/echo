import SwiftUI

/// The stories rail — the window's first element, top to bottom (cockpit sit
/// 2026-08-21): one fluid ORB per open lane, the AI-assistant identity.
/// Orb v2 (Ranny's direction): a HOLLOW sphere of something fluid — a nearly
/// clear heart with color gathering at the rim, a morphing liquid line and
/// drifting particles inside, two translucent swirls over it. No initials,
/// no rings: STATUS is the color (teal working · orange attention · violet
/// finished-with-unheard · slate ready · gray ghost), and color changes
/// tween fluidly instead of snapping. Working lanes swirl; the speaking lane
/// breathes with the live audio level; stopped lanes hold a still
/// constellation. The unheard dot sits beside the name now, half its old
/// size, leaving the sphere clean.
struct LaneInfo: Identifiable {
    let id: String          // lane key ("" = untagged legacy clips)
    let name: String        // display name (custom or prettified basename)
    let state: String?      // ready|working|attention|finished|closed; nil = no status feed
    let unplayed: Int
    let lastActivity: Date
    let isMain: Bool
    let isOpen: Bool
    /// A lane the status feed doesn't know (its session closed before it could
    /// say so, or long ago): still tappable, clearly dead — gray, still, last —
    /// and it vanishes with the 24h sweep (Ranny's call: ghosts over hiding).
    let isGhost: Bool

    var displayName: String { name }
}

struct LaneRailView: View {
    @ObservedObject var client: EchoClient
    @State private var renamingLane: String?
    @State private var renameText = ""

    var body: some View {
        let lanes = client.lanes
        let speakingLane = (client.isPlaying && !client.isPaused)
            ? client.nowPlayingClip?.lane : nil
        if !lanes.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(lanes) { info in
                        LaneCircle(info: info,
                                   isSpeaking: info.id == speakingLane,
                                   level: client.audioLevel) {
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

/// One lane's orb + its name. The sphere is pure status-and-motion; identity
/// lives in a lane-keyed tint woven through the swirl and in the name below.
struct LaneCircle: View {
    let info: LaneInfo
    let isSpeaking: Bool
    let level: Double
    let open: () -> Void
    let setMain: (Bool) -> Void
    let rename: () -> Void

    private var animated: Bool {
        !info.isGhost && (isSpeaking || info.state == "working")
    }

    var body: some View {
        Button(action: open) {
            VStack(spacing: 4) {
                orb
                    .frame(width: 54, height: 54)
                    .overlay(alignment: .bottomTrailing) {
                        if info.isMain {
                            Image(systemName: "star.circle.fill")
                                .font(.system(size: 15))
                                .symbolRenderingMode(.multicolor)
                                .background(Circle().fill(.background))
                        }
                    }
                Text(info.displayName)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(info.isOpen ? AnyShapeStyle(.tint)
                                                 : AnyShapeStyle(.secondary))
                    .opacity(info.isGhost ? 0.6 : 1)
                    // The unheard dot rides absolute at the name's top-right,
                    // grazing above the last character — transient, never in
                    // the reading path, never on the sphere.
                    .overlay(alignment: .topTrailing) {
                        if info.unplayed > 0 {
                            Circle().fill(Color.accentColor)
                                .frame(width: 5, height: 5)
                                .offset(x: 7, y: -2)
                        }
                    }
                    .frame(width: 76)
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
    }

    /// The hollow fluid sphere. TimelineView pauses entirely for still lanes,
    /// so idle orbs cost nothing; at phase 0 the line and particles hold a
    /// still constellation.
    private var orb: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !animated)) { tl in
            orbBody(phase: animated ? tl.date.timeIntervalSinceReferenceDate : 0)
        }
    }

    @ViewBuilder private func orbBody(phase: Double) -> some View {
        let pal = palette
        let seed = Self.stableHue(info.id) * 6.28318
        ZStack {
            // Hollow shell: nearly clear heart, color gathering at the rim.
            Circle().fill(RadialGradient(
                stops: [.init(color: pal.light.opacity(0.10), location: 0),
                        .init(color: pal.light.opacity(0.30), location: 0.62),
                        .init(color: pal.dark.opacity(0.85), location: 1)],
                center: UnitPoint(x: 0.42, y: 0.36),
                startRadius: 1, endRadius: 30))
            // Two translucent liquid swirls.
            Circle()
                .fill(AngularGradient(
                    colors: [.clear, pal.swirl.opacity(0.55), .clear,
                             .white.opacity(0.18), .clear],
                    center: .center))
                .rotationEffect(.radians(phase * 0.8))
                .blur(radius: 5)
            Circle()
                .fill(AngularGradient(
                    colors: [.clear, identityTint.opacity(0.40), .clear],
                    center: .center))
                .rotationEffect(.radians(-phase * 1.35 + 2))
                .blur(radius: 7)
            // The fluid interior (orb v3, Ranny's polish): micro-photons that
            // twinkle in and out as they drift, each casting a faint prismatic
            // refraction; and a SURFACE wave — an envelope-gated ripple hugging
            // the rim, so occasionally the sphere's skin seems to undulate
            // without the wave itself ever being an object you look at.
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = min(size.width, size.height) / 2
                // Surface wave: mostly invisible; fades in on a slow envelope.
                let env = pow(max(0, sin(phase * 0.23 + seed)), 4)
                if env > 0.02 {
                    let n = 72
                    func rimPath(inset: Double, phi: Double, amp: Double) -> Path {
                        var p = Path()
                        for i in 0...n {
                            let th = Double(i) / Double(n) * 6.28318
                            let r = R - inset + amp * sin(3 * th - phase * 1.2 + seed + phi)
                            let pt = CGPoint(x: c.x + CGFloat(cos(th) * r),
                                             y: c.y + CGFloat(sin(th) * r))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                        p.closeSubpath()
                        return p
                    }
                    ctx.stroke(rimPath(inset: 1.8, phi: 0, amp: 1.9),
                               with: .color(pal.light.opacity(0.40 * env)), lineWidth: 1.6)
                    ctx.stroke(rimPath(inset: 3.2, phi: .pi, amp: 1.4),
                               with: .color(pal.dark.opacity(0.35 * env)), lineWidth: 1.2)
                }
                // Micro-photons: many, tiny, light-emitting, intermittent.
                // (Arithmetic kept in explicit Double steps — one fused
                // expression here sent the type-checker into the weeds.)
                let prismA = Color(hue: 0.55, saturation: 0.85, brightness: 1)
                let prismB = Color(hue: 0.83, saturation: 0.75, brightness: 1)
                let RR = Double(R)
                let cx = Double(c.x)
                let cy = Double(c.y)
                for i in 0..<22 {
                    let fi = Double(i)
                    let sp: Double = 0.25 + 0.11 * fi.truncatingRemainder(dividingBy: 4)
                    let ang: Double = phase * sp + seed + fi * 0.9
                    let breath: Double = sin(phase * (0.4 + 0.07 * fi) + fi * 2.1 + seed)
                    let rr: Double = RR * (0.12 + 0.62 * (0.5 + 0.5 * breath))
                    // Twinkle envelope: each photon has its own show/hide cycle.
                    let twRaw: Double = sin(phase * (0.7 + 0.13 * fi) + fi * 1.3 + seed * 3)
                    let tw: Double = pow(max(0, twRaw), 3)
                    guard tw > 0.03 else { continue }
                    let px: Double = cx + cos(ang) * rr
                    let py: Double = cy + sin(ang) * rr
                    let pt = CGPoint(x: px, y: py)
                    // Prismatic halo: white heart refracting into spectral
                    // cyan/magenta before it fades — the refraction effect.
                    let halo: Double = 1.5 + 3.5 * tw
                    let haloRect = CGRect(x: px - halo, y: py - halo,
                                          width: halo * 2, height: halo * 2)
                    let stops: [Gradient.Stop] = [
                        .init(color: Color.white.opacity(0.50 * tw), location: 0),
                        .init(color: prismA.opacity(0.26 * tw), location: 0.45),
                        .init(color: prismB.opacity(0.16 * tw), location: 0.75),
                        .init(color: Color.clear, location: 1)
                    ]
                    ctx.fill(Path(ellipseIn: haloRect),
                             with: .radialGradient(Gradient(stops: stops),
                                                   center: pt, startRadius: 0,
                                                   endRadius: halo))
                    let d: Double = 0.8 + 0.8 * tw
                    let coreRect = CGRect(x: px - d / 2, y: py - d / 2,
                                          width: d, height: d)
                    ctx.fill(Path(ellipseIn: coreRect),
                             with: .color(Color.white.opacity(0.85 * tw)))
                }
            }
        }
        .clipShape(Circle())
        // The atmosphere: a whisper of glow hugging the sphere's border.
        .shadow(color: pal.light.opacity(0.45), radius: 2.5)
        .shadow(color: pal.swirl.opacity(0.22), radius: 6)
        .scaleEffect(1 + (isSpeaking ? min(level, 1) * 0.22 : 0))
        .animation(.easeOut(duration: 0.12), value: level)
        // Status changes flow, never snap (Ranny): tween the whole palette.
        .animation(.easeInOut(duration: 0.9), value: paletteKey)
        .opacity(info.isGhost ? 0.5 : 1)
    }

    private var paletteKey: String {
        "\(info.state ?? "-")|\(info.unplayed > 0)|\(info.isGhost)"
    }

    /// Status IS the color (the ring died with orb v1 already).
    private var palette: (light: Color, dark: Color, swirl: Color) {
        if info.isGhost {
            return (Color(white: 0.55), Color(white: 0.32), Color(white: 0.65))
        }
        switch info.state {
        case "working":
            return (Color(hue: 0.47, saturation: 0.55, brightness: 0.88),
                    Color(hue: 0.52, saturation: 0.85, brightness: 0.42),
                    Color(hue: 0.44, saturation: 0.70, brightness: 0.92))
        case "attention":
            return (Color(hue: 0.09, saturation: 0.65, brightness: 0.95),
                    Color(hue: 0.05, saturation: 0.90, brightness: 0.50),
                    Color(hue: 0.12, saturation: 0.80, brightness: 0.95))
        case "ready":
            return (Color(hue: 0.58, saturation: 0.12, brightness: 0.72),
                    Color(hue: 0.60, saturation: 0.20, brightness: 0.40),
                    Color(hue: 0.58, saturation: 0.15, brightness: 0.80))
        default:
            // finished (and feed-less lanes): Siri violet while something is
            // unheard, calm blue-gray once everything was listened to.
            if info.unplayed > 0 {
                return (Color(hue: 0.72, saturation: 0.55, brightness: 0.92),
                        Color(hue: 0.78, saturation: 0.80, brightness: 0.45),
                        Color(hue: 0.66, saturation: 0.70, brightness: 0.95))
            }
            return (Color(hue: 0.62, saturation: 0.18, brightness: 0.66),
                    Color(hue: 0.64, saturation: 0.28, brightness: 0.36),
                    Color(hue: 0.60, saturation: 0.22, brightness: 0.75))
        }
    }

    /// A stable per-lane tint: djb2 over the lane KEY (not the editable
    /// name), so a lane keeps its hue across renames and launches.
    private var identityTint: Color {
        Color(hue: Self.stableHue(info.id), saturation: 0.6, brightness: 0.85)
    }

    private static func stableHue(_ s: String) -> Double {
        var h: UInt32 = 5381
        for u in s.unicodeScalars { h = h &* 33 &+ u.value }
        return Double(h % 360) / 360
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
