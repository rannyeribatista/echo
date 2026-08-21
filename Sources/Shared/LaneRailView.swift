import SwiftUI

/// The stories rail, final form of the cockpit iteration (2026-08-21):
/// the SELECTED lane's orb sits centered and featured at 115% size; every
/// other lane rides a horizontal scroll beneath it at 50% — the assistant
/// front and center, the fleet at a glance. Orbs are parametric (`unit`), so
/// the small ones render crisp instead of scaled-blurry, and selection moves
/// between tiers with a matched-geometry spring.
///
/// The orb itself: a hollow sphere — clear heart, color at the rim, an
/// earth-limb glow melting the border — threaded by a chromatic pole-pinned
/// ribbon (ONE sine skew, near-white at its brightest reach, spectral
/// dispersion around it) rotating a full longitude every 5s while the axis
/// slowly spins. The wall yields: gaussian bulges where the ribbon presses
/// the border (total push capped so no canvas can guillotine it). STATUS is
/// the color; changes tween 0.9s; the speaking orb breathes with the live
/// audio level; motion coasts ~1.2s after speech/work ends.
struct LaneInfo: Identifiable {
    let id: String          // lane key ("" = untagged legacy clips)
    let name: String        // display name (custom or titleized basename)
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

/// The sphere's wall: a circle whose radius yields with small gaussian bulges
/// where the ribbon presses it. The TOTAL push is capped (scaled with the
/// sphere) so overlapping bulges can never outgrow the paint canvas.
struct BulgeCircle: InsettableShape {
    var radius: Double
    var angles: [Double]
    var amounts: [Double]
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let baseR = radius - Double(insetAmount)
        let maxPush = 5.0 * (radius / 27.0)
        var path = Path()
        let n = 72
        for i in 0...n {
            let th = Double(i) / Double(n) * 6.28318 - 3.14159
            var push = 0.0
            for j in 0..<min(angles.count, amounts.count) {
                var d = th - angles[j]
                while d > 3.14159 { d -= 6.28318 }
                while d < -3.14159 { d += 6.28318 }
                push += amounts[j] * exp(-(d * d) / 0.16)
            }
            let r = baseR + min(push, maxPush)
            let pt = CGPoint(x: c.x + CGFloat(cos(th) * r),
                             y: c.y + CGFloat(sin(th) * r))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> BulgeCircle {
        var s = self
        s.insetAmount += amount
        return s
    }
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
            VStack(spacing: 6) {
                if let featured = lanes.first(where: { $0.isOpen }) {
                    // In-place morph, not a cross-container flight: matched
                    // geometry breaks across a ScrollView (clipped traveler,
                    // stale-frame pairing — Ranny's artifact). The promoted
                    // orb grows into this slot; the demoted one shrinks into
                    // the row.
                    circle(featured, speakingLane: speakingLane, unit: 1.15)
                        .id(featured.id)
                        .transition(.scale(scale: 0.45).combined(with: .opacity))
                        .frame(maxWidth: .infinity)
                }
                let rest = lanes.filter { !$0.isOpen }
                if !rest.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(rest) { info in
                                circle(info, speakingLane: speakingLane, unit: 0.5)
                                    .transition(.scale(scale: 1.8).combined(with: .opacity))
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                        .padding(.bottom, 2)
                    }
                }
            }
            .animation(.spring(response: 0.42, dampingFraction: 0.85),
                       value: client.openLane)
        }
    }

    @ViewBuilder private func circle(_ info: LaneInfo, speakingLane: String?,
                                     unit: Double) -> some View {
        LaneCircle(info: info,
                   unit: unit,
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
                TextField(info.id.isEmpty ? "untagged" : info.id, text: $renameText)
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

/// One lane's orb + its name, parametric in `unit` (1.15 featured · 0.5
/// compact): every geometric constant scales, so small orbs are drawn small,
/// never downscaled bitmaps.
struct LaneCircle: View {
    let info: LaneInfo
    let unit: Double
    let isSpeaking: Bool
    let level: Double
    let open: () -> Void
    let setMain: (Bool) -> Void
    let rename: () -> Void

    @State private var coasting = false

    private var animated: Bool {
        !info.isGhost && (isSpeaking || info.state == "working")
    }

    /// Sphere radius at this size.
    private var sphereR: Double { 27 * unit }
    /// Paint canvas: sphere + max push + limb blur, with margin — nothing
    /// inside can be guillotined.
    private var canvasSide: Double { (27 + 5 + 6) * 2 * unit }

    var body: some View {
        Button(action: open) {
            VStack(spacing: 7 * unit) {
                orb
                    .frame(width: canvasSide + 12 * unit,
                           height: canvasSide + 12 * unit)
                    .overlay(alignment: .bottomTrailing) {
                        if info.isMain {
                            Image(systemName: "star.circle.fill")
                                .font(.system(size: max(15 * unit, 10)))
                                .symbolRenderingMode(.multicolor)
                                .background(Circle().fill(.background))
                                .offset(x: -13 * unit, y: -13 * unit)
                        }
                    }
                Text(info.displayName)
                    .font(.system(size: unit >= 1 ? 11 : 9))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(info.isOpen ? AnyShapeStyle(.tint)
                                                 : AnyShapeStyle(.secondary))
                    .opacity(info.isGhost ? 0.6 : 1)
                    // The unheard dot rides absolute at the name's top-right,
                    // grazing above the last character.
                    .overlay(alignment: .topTrailing) {
                        if info.unplayed > 0 {
                            Circle().fill(Color.accentColor)
                                .frame(width: unit >= 1 ? 5 : 4,
                                       height: unit >= 1 ? 5 : 4)
                                .offset(x: 7, y: -2)
                        }
                    }
                    .frame(width: unit >= 1 ? 96 : 52)
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

    private var orb: some View {
        TimelineView(.animation(minimumInterval: 1 / 24,
                                paused: !(animated || coasting))) { tl in
            LaneOrbView(info: info, unit: unit,
                        phase: (animated || coasting)
                        ? tl.date.timeIntervalSinceReferenceDate : 0,
                        isSpeaking: isSpeaking, level: level)
        }
        // Motion coasts for a beat after speech/work ends instead of freezing
        // mid-swirl.
        .onChange(of: animated) { on in
            if !on {
                coasting = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    coasting = false
                }
            }
        }
    }

}

/// The sphere itself, standalone — LaneCircle renders it live through its
/// TimelineView, and the icon exporter renders the very same view frozen at a
/// chosen phase (the icon IS the real thing).
struct LaneOrbView: View {
    let info: LaneInfo
    let unit: Double
    let phase: Double
    let isSpeaking: Bool
    let level: Double

    /// Sphere radius at this size.
    private var sphereR: Double { 27 * unit }
    private var canvasSide: Double { (27 + 5 + 6) * 2 * unit }

    var body: some View {
        let pal = palette
        // Blur scales sub-linearly: identical at rail sizes (unit near 1),
        // crisp instead of washed at icon scale (unit 8+).
        let bl = pow(unit, 0.58)
        let seed = Self.stableHue(info.id) * 6.28318
        let longitude: Double = phase * 1.2566        // 2π / 5s — full turn every 5s
        let spinAxis: Double = phase * 0.12 + seed    // the poles themselves spin, slowly
        let cosA = cos(spinAxis)
        let sinA = sin(spinAxis)
        let wall = wallShape(phase: phase, longitude: longitude,
                             cosA: cosA, sinA: sinA, seed: seed)
        let u = unit
        ZStack {
            // Hollow shell: nearly clear heart, color gathering at the rim.
            Circle().fill(RadialGradient(
                stops: [.init(color: pal.light.opacity(0.10), location: 0),
                        .init(color: pal.light.opacity(0.30), location: 0.62),
                        .init(color: pal.dark.opacity(0.85), location: 1)],
                center: UnitPoint(x: 0.42, y: 0.36),
                startRadius: 1, endRadius: 30 * u))
            // Two translucent liquid swirls — they opt OUT of the palette
            // tween (their ever-advancing rotation would ease into a fast
            // spin during status changes).
            Circle()
                .fill(AngularGradient(
                    colors: [.clear, pal.swirl.opacity(0.40), .clear,
                             .white.opacity(0.14), .clear],
                    center: .center))
                .rotationEffect(.radians(phase * 0.8))
                .blur(radius: 5 * bl)
                .animation(nil, value: paletteKey)
            Circle()
                .fill(AngularGradient(
                    colors: [.clear, identityTint.opacity(0.30), .clear],
                    center: .center))
                .rotationEffect(.radians(-phase * 1.35 + 2))
                .blur(radius: 7 * bl)
                .animation(nil, value: paletteKey)
            // The chromatic ribbon — the pole-to-pole line: pinned at both
            // poles, ONE drastic sine skew, a full rotation every 5 seconds,
            // spectral dispersion around a near-white core.
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let R = 27.0 * u                   // sphere radius — NOT the canvas rect
                let cx = Double(c.x)
                let cy = Double(c.y)

                func ribbon(longitude: Double, wobSeed: Double, alpha: Double) {
                    let m = 40
                    var pts: [CGPoint] = []
                    pts.reserveCapacity(m + 1)
                    let sinL = sin(longitude)
                    for i in 0...m {
                        let t01 = Double(i) / Double(m)
                        let th = t01 * Double.pi
                        let sth = sin(th)
                        let y0: Double = -cos(th) * R * 0.92
                        let base: Double = sth * sinL * R * 0.82
                        // ONE sine deformation — drastic but pure.
                        let w1: Double = 0.50 * sin(2.2 * t01 * Double.pi + phase * 0.9 + wobSeed)
                        let skew: Double = sth * R * w1
                        let x0: Double = base + skew
                        let xr: Double = x0 * cosA - y0 * sinA
                        let yr: Double = x0 * sinA + y0 * cosA
                        pts.append(CGPoint(x: cx + xr, y: cy + yr))
                    }
                    // Spectral dispersion: parallel slivers of the spectrum.
                    let spectrum: [(Double, Double)] = [(-2.4 * u, 0.50), (-1.2 * u, 0.83),
                                                        (0, 0.33), (1.2 * u, 0.12), (2.4 * u, 0.66)]
                    for (off, hue) in spectrum {
                        var path = Path()
                        for (i, pt) in pts.enumerated() {
                            let q = CGPoint(x: pt.x + off * cosA, y: pt.y + off * sinA)
                            if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                        }
                        ctx.stroke(path,
                                   with: .color(Color(hue: hue, saturation: 0.85,
                                                      brightness: 1).opacity(0.45 * alpha)),
                                   lineWidth: 2.2 * u)
                    }
                    // The light itself: graded core, near FULL WHITE at the
                    // ribbon's strongest reach, dimming toward the poles.
                    // Overlapping 3-point segments: short-segment beading
                    // shows at icon scale; overlap melts it into a filament.
                    for i in 0..<(pts.count - 2) {
                        let t01 = Double(i) / Double(m)
                        let e = pow(sin(t01 * Double.pi), 1.6)
                        let a = (0.13 + 0.45 * e) * alpha
                        var seg = Path()
                        seg.move(to: pts[i])
                        seg.addLine(to: pts[i + 1])
                        seg.addLine(to: pts[i + 2])
                        ctx.stroke(seg, with: .color(pal.core.opacity(a)),
                                   lineWidth: (1.3 + 1.3 * e) * u)
                    }
                }

                ctx.addFilter(.blur(radius: max(1.3 * bl, 0.7)))
                ribbon(longitude: longitude, wobSeed: seed, alpha: 1)
                ribbon(longitude: longitude + 2.3, wobSeed: seed * 3 + 1.7, alpha: 0.55)
            }
        }
        .frame(width: canvasSide, height: canvasSide)
        .clipShape(wall)
        // The atmosphere (earth-limb treatment): a blurred bright rim melts
        // the sharp edge; the limb rides the yielding wall, so pushes glow too.
        .overlay {
            wall.strokeBorder(pal.light.opacity(0.75), lineWidth: 1.6 * u)
                .blur(radius: 2.2 * bl)
        }
        .padding(6 * u)
        .shadow(color: pal.light.opacity(0.85), radius: 2.5 * u)
        .shadow(color: pal.swirl.opacity(0.45), radius: 6 * u)
        .scaleEffect(1 + (isSpeaking ? min(level, 1) * 0.22 : 0))
        .animation(.easeOut(duration: 0.12), value: level)
        // Status changes flow, never snap: tween the whole palette.
        .animation(.easeInOut(duration: 0.9), value: paletteKey)
        .opacity(info.isGhost ? 0.5 : 1)
    }

    /// Where the ribbon presses the wall: sample the same meridian math; any
    /// point crossing the contact radius bends the sphere outward.
    private func wallShape(phase: Double, longitude: Double,
                           cosA: Double, sinA: Double, seed: Double) -> BulgeCircle {
        let R0 = sphereR
        var angles: [Double] = []
        var amounts: [Double] = []
        let sinL0 = sin(longitude)
        for i in stride(from: 0, through: 40, by: 4) {
            let t01 = Double(i) / 40.0
            let th = t01 * Double.pi
            let sth = sin(th)
            let y0: Double = -cos(th) * R0 * 0.92
            let base: Double = sth * sinL0 * R0 * 0.82
            let w1: Double = 0.50 * sin(2.2 * t01 * Double.pi + phase * 0.9 + seed)
            let x0: Double = base + sth * R0 * w1
            let xr: Double = x0 * cosA - y0 * sinA
            let yr: Double = x0 * sinA + y0 * cosA
            let dist = (xr * xr + yr * yr).squareRoot()
            let thr = R0 * 0.88
            if dist > thr {
                angles.append(atan2(yr, xr))
                amounts.append(min((dist - thr) * 0.8, 3.0 * unit))
            }
        }
        return BulgeCircle(radius: R0, angles: angles, amounts: amounts)
    }

    private var paletteKey: String {
        "\(info.state ?? "-")|\(info.unplayed > 0)|\(info.isGhost)"
    }

    /// Status IS the color. `core` is the filament: the ribbon emits light in
    /// the sphere's own spectrum — nearly white, tinted by the status hue
    /// (Ranny: a green sphere carries an almost-white green line, violet an
    /// almost-white violet, amber an almost-white amber).
    private var palette: (light: Color, dark: Color, swirl: Color, core: Color) {
        if info.isGhost {
            return (Color(white: 0.55), Color(white: 0.32), Color(white: 0.65),
                    Color(white: 0.95))
        }
        switch info.state {
        case "working":
            return (Color(hue: 0.47, saturation: 0.55, brightness: 0.88),
                    Color(hue: 0.52, saturation: 0.85, brightness: 0.42),
                    Color(hue: 0.44, saturation: 0.70, brightness: 0.92),
                    Color(hue: 0.45, saturation: 0.32, brightness: 1.0))
        case "attention":
            return (Color(hue: 0.09, saturation: 0.65, brightness: 0.95),
                    Color(hue: 0.05, saturation: 0.90, brightness: 0.50),
                    Color(hue: 0.12, saturation: 0.80, brightness: 0.95),
                    Color(hue: 0.10, saturation: 0.35, brightness: 1.0))
        case "ready":
            return (Color(hue: 0.58, saturation: 0.12, brightness: 0.72),
                    Color(hue: 0.60, saturation: 0.20, brightness: 0.40),
                    Color(hue: 0.58, saturation: 0.15, brightness: 0.80),
                    Color(hue: 0.58, saturation: 0.15, brightness: 0.98))
        default:
            // finished (and feed-less lanes): Siri violet while something is
            // unheard, calm blue-gray once everything was listened to.
            if info.unplayed > 0 {
                return (Color(hue: 0.72, saturation: 0.55, brightness: 0.92),
                        Color(hue: 0.78, saturation: 0.80, brightness: 0.45),
                        Color(hue: 0.66, saturation: 0.70, brightness: 0.95),
                        Color(hue: 0.70, saturation: 0.30, brightness: 1.0))
            }
            return (Color(hue: 0.62, saturation: 0.18, brightness: 0.66),
                    Color(hue: 0.64, saturation: 0.28, brightness: 0.36),
                    Color(hue: 0.60, saturation: 0.22, brightness: 0.75),
                    Color(hue: 0.62, saturation: 0.18, brightness: 0.96))
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

}

private extension LaneCircle {
    var helpText: String {
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

/// Lane utils: the open lane's curated links — a dev server, the design
/// canvas, anything external — as tappable chips. Registered from any
/// terminal via echo-link.sh; same chips on the phone.
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
