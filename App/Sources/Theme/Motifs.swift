import SwiftUI

/// Deterministic pseudo-random numbers so decorations are identical on every launch.
struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0x7FFFFFFF) / Double(0x7FFFFFFF)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

/// Full-window themed background: gradient, a soft glow and a restrained static motif.
/// Drawn with Canvas (one rasterised layer, no per-frame work) so it costs almost nothing.
struct ThemeBackdrop: View {
    @Environment(\.hmoTheme) private var theme
    var showMotif = true
    var intensity: Double = 1

    var body: some View {
        let p = theme.palette
        ZStack {
            theme.background
            RadialGradient(colors: [p.glow, p.glow.opacity(0)], center: UnitPoint(x: 0.72, y: 0.08), startRadius: 10, endRadius: 620)
                .blendMode(theme.scheme == .dark ? .plusLighter : .normal)
                .opacity(theme.scheme == .dark ? 0.55 : 0.9)
            if showMotif {
                MotifCanvas(motif: theme.theme.motif, ink: p.motif, accent: p.accent, wave: p.wave, scheme: theme.scheme)
                    .opacity(p.motifOpacity * intensity)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

struct MotifCanvas: View {
    let motif: Motif
    let ink: Color
    let accent: Color
    let wave: [Color]
    let scheme: ColorScheme

    var body: some View {
        Canvas(rendersAsynchronously: true) { ctx, size in
            MotifPainter(ctx: ctx, size: size, ink: ink, accent: accent, wave: wave, scheme: scheme).draw(motif)
        }
        .accessibilityHidden(true)
    }
}

private struct MotifPainter {
    var ctx: GraphicsContext
    let size: CGSize
    let ink: Color
    let accent: Color
    let wave: [Color]
    let scheme: ColorScheme

    var w: CGFloat { size.width }
    var h: CGFloat { size.height }

    func draw(_ motif: Motif) {
        switch motif {
        case .leaves: leaves()
        case .waves: waves()
        case .sun: sun()
        case .lavender: lavender()
        case .depths: depths()
        case .petals: petals()
        case .pines: pines()
        case .studio: studio()
        case .blossom: blossom()
        case .rays: rays()
        case .mountains: mountains()
        case .dunes: dunes()
        case .meadow: meadow()
        case .linen: linen()
        case .aurora: aurora()
        case .steam: steam()
        }
    }

    // MARK: Botanical — fern fronds curling in from the corners

    private func frond(from start: CGPoint, angle: CGFloat, length: CGFloat, curl: CGFloat, leafSize: CGFloat, color: Color) {
        var spine = Path()
        spine.move(to: start)
        var pts: [CGPoint] = []
        var a: CGFloat = angle
        var p = start
        let steps = 22
        let stepLength: CGFloat = length / CGFloat(steps)
        for _ in 0..<steps {
            let dx: CGFloat = cos(a) * stepLength
            let dy: CGFloat = sin(a) * stepLength
            p = CGPoint(x: p.x + dx, y: p.y + dy)
            pts.append(p)
            spine.addLine(to: p)
            a += curl / CGFloat(steps)
        }
        ctx.stroke(spine, with: .color(color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        for (i, q) in pts.enumerated() where i % 2 == 0 {
            let t: CGFloat = 1 - CGFloat(i) / CGFloat(steps)
            let ls: CGFloat = leafSize * (0.35 + t * 0.75)
            let dir: CGFloat = angle + curl * CGFloat(i) / CGFloat(steps)
            for side in [CGFloat(-1), CGFloat(1)] {
                let la: CGFloat = dir + side * 1.05
                let tip = CGPoint(x: q.x + cos(la) * ls, y: q.y + sin(la) * ls)
                let a1: CGFloat = la - 0.45 * side
                let a2: CGFloat = la + 0.45 * side
                let c1 = CGPoint(x: q.x + cos(a1) * ls * 0.6, y: q.y + sin(a1) * ls * 0.6)
                let c2 = CGPoint(x: q.x + cos(a2) * ls * 0.6, y: q.y + sin(a2) * ls * 0.6)
                var leaf = Path()
                leaf.move(to: q)
                leaf.addQuadCurve(to: tip, control: c1)
                leaf.addQuadCurve(to: q, control: c2)
                ctx.fill(leaf, with: .color(color.opacity(0.75)))
            }
        }
    }

    func leaves() {
        frond(from: CGPoint(x: w + 10, y: h * 0.62), angle: .pi * 1.08, length: min(w, h) * 0.55, curl: -0.9, leafSize: 26, color: ink)
        frond(from: CGPoint(x: w + 20, y: h * 0.82), angle: .pi * 1.18, length: min(w, h) * 0.42, curl: -0.6, leafSize: 22, color: ink.opacity(0.7))
        frond(from: CGPoint(x: -10, y: h + 10), angle: -.pi * 0.32, length: min(w, h) * 0.5, curl: 0.7, leafSize: 24, color: ink.opacity(0.8))
        frond(from: CGPoint(x: w * 0.06, y: -10), angle: .pi * 0.38, length: min(w, h) * 0.28, curl: 0.6, leafSize: 16, color: ink.opacity(0.45))
    }

    // MARK: Coastal — layered soft waves along the bottom

    func waves() {
        for i in 0..<5 {
            let base = h * (0.70 + CGFloat(i) * 0.065)
            let amp = 10 + CGFloat(i) * 3
            var path = Path()
            path.move(to: CGPoint(x: 0, y: base))
            var x: CGFloat = 0
            while x <= w + 20 {
                let y = base + sin(Double(x) / Double(140 + i * 30) + Double(i) * 1.3) * Double(amp)
                path.addLine(to: CGPoint(x: x, y: y))
                x += 8
            }
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: 0, y: h))
            path.closeSubpath()
            let c = wave[i % wave.count]
            ctx.fill(path, with: .color(c.opacity(0.10 + Double(i) * 0.05)))
        }
        var rng = SeededRandom(7)
        for _ in 0..<14 {
            let x = rng.range(0, Double(w)), y = rng.range(Double(h) * 0.05, Double(h) * 0.35)
            let r = rng.range(1.5, 3.5)
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(ink.opacity(0.4)))
        }
    }

    // MARK: Sunset — a low sun with banded reflections

    func sun() {
        let c = CGPoint(x: w * 0.78, y: h * 0.78)
        let r = min(w, h) * 0.26
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                 with: .linearGradient(Gradient(colors: wave.reversed().map { $0.opacity(0.55) }), startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)))
        for i in 0..<7 {
            let y = c.y + r * 0.15 + CGFloat(i) * 12
            let half = r * (1.1 - CGFloat(i) * 0.08)
            var band = Path()
            band.addRoundedRect(in: CGRect(x: c.x - half, y: y, width: half * 2, height: 3.5), cornerSize: CGSize(width: 2, height: 2))
            ctx.fill(band, with: .color(ink.opacity(0.5 - Double(i) * 0.05)))
        }
        var horizon = Path()
        horizon.move(to: CGPoint(x: 0, y: h * 0.9))
        horizon.addCurve(to: CGPoint(x: w, y: h * 0.86), control1: CGPoint(x: w * 0.3, y: h * 0.84), control2: CGPoint(x: w * 0.6, y: h * 0.94))
        horizon.addLine(to: CGPoint(x: w, y: h)); horizon.addLine(to: CGPoint(x: 0, y: h)); horizon.closeSubpath()
        ctx.fill(horizon, with: .color(ink.opacity(0.25)))
    }

    // MARK: Lavender — sprigs rising from the bottom edge

    func lavender() {
        var rng = SeededRandom(11)
        let count = Int(w / 42)
        for i in 0..<count {
            let x = CGFloat(i) * 42 + CGFloat(rng.range(-10, 10))
            let height = CGFloat(rng.range(Double(h) * 0.12, Double(h) * 0.3))
            let lean = CGFloat(rng.range(-18, 18))
            var stem = Path()
            stem.move(to: CGPoint(x: x, y: h + 4))
            stem.addQuadCurve(to: CGPoint(x: x + lean, y: h - height), control: CGPoint(x: x + lean * 0.2, y: h - height * 0.5))
            ctx.stroke(stem, with: .color(ink.opacity(0.55)), lineWidth: 1.4)
            let buds = 7
            for b in 0..<buds {
                let t = 0.62 + 0.38 * Double(b) / Double(buds)
                let bx = x + lean * CGFloat(t * t) , by = h - height * CGFloat(t)
                for side in [-1.0, 1.0] {
                    let rect = CGRect(x: bx + CGFloat(side) * 3 - 3, y: by - 4, width: 6, height: 9)
                    ctx.fill(Path(ellipseIn: rect), with: .color(accent.opacity(0.55 - Double(b) * 0.03)))
                }
            }
        }
    }

    // MARK: Ocean — light shafts and rising bubbles

    func depths() {
        for i in 0..<4 {
            var ray = Path()
            let x = w * (0.18 + CGFloat(i) * 0.2)
            ray.move(to: CGPoint(x: x - 30, y: 0))
            ray.addLine(to: CGPoint(x: x + 30, y: 0))
            ray.addLine(to: CGPoint(x: x + 140, y: h))
            ray.addLine(to: CGPoint(x: x + 20, y: h))
            ray.closeSubpath()
            ctx.fill(ray, with: .linearGradient(Gradient(colors: [ink.opacity(0.35), ink.opacity(0)]), startPoint: CGPoint(x: x, y: 0), endPoint: CGPoint(x: x, y: h)))
        }
        var rng = SeededRandom(3)
        for _ in 0..<38 {
            let x = rng.range(Double(w) * 0.55, Double(w)), y = rng.range(Double(h) * 0.2, Double(h))
            let r = rng.range(2, 9)
            ctx.stroke(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(wave.last!.opacity(0.6)), lineWidth: 1)
        }
    }

    // MARK: Rosewater — scattered petals

    func petals() {
        var rng = SeededRandom(21)
        for i in 0..<26 {
            let corner = i % 2 == 0
            let x = corner ? rng.range(Double(w) * 0.7, Double(w)) : rng.range(0, Double(w) * 0.28)
            let y = corner ? rng.range(0, Double(h) * 0.4) : rng.range(Double(h) * 0.62, Double(h))
            let s = rng.range(10, 24)
            var petal = Path()
            petal.move(to: .zero)
            petal.addQuadCurve(to: CGPoint(x: 0, y: s), control: CGPoint(x: s * 0.7, y: s * 0.4))
            petal.addQuadCurve(to: .zero, control: CGPoint(x: -s * 0.7, y: s * 0.4))
            var t = ctx
            t.translateBy(x: x, y: y)
            t.rotate(by: .radians(rng.range(0, .pi * 2)))
            t.fill(petal, with: .color((i % 3 == 0 ? accent : ink).opacity(0.5)))
        }
    }

    // MARK: Forest — layered pine silhouettes

    func pines() {
        var rng = SeededRandom(5)
        for layer in 0..<3 {
            let base = h * (0.86 + CGFloat(layer) * 0.06)
            var x: CGFloat = CGFloat(rng.range(-20, 10))
            while x < w + 40 {
                let th = CGFloat(rng.range(70, 150)) * (1 - CGFloat(layer) * 0.18)
                let tw = th * 0.42
                var tree = Path()
                for tier in 0..<3 {
                    let top = base - th + CGFloat(tier) * th * 0.24
                    let half = tw * (0.45 + CGFloat(tier) * 0.28) / 2
                    tree.move(to: CGPoint(x: x, y: top))
                    tree.addLine(to: CGPoint(x: x + half, y: top + th * 0.42))
                    tree.addLine(to: CGPoint(x: x - half, y: top + th * 0.42))
                    tree.closeSubpath()
                }
                tree.addRect(CGRect(x: x - 2, y: base - th * 0.1, width: 4, height: th * 0.12))
                ctx.fill(tree, with: .color(ink.opacity(0.35 + Double(layer) * 0.2)))
                x += tw * CGFloat(rng.range(0.7, 1.2))
            }
        }
    }

    // MARK: Midnight Studio — acoustic-panel dot grid and soft rings

    func studio() {
        let spacing: CGFloat = 26
        var y: CGFloat = spacing
        while y < h {
            var x: CGFloat = spacing
            while x < w {
                let d = hypot(x - w * 0.5, y - h * 0.45) / max(w, h)
                let o = max(0, 0.55 - d)
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(ink.opacity(o)))
                x += spacing
            }
            y += spacing
        }
        for i in 1...4 {
            let r = CGFloat(i) * min(w, h) * 0.16
            ctx.stroke(Path(ellipseIn: CGRect(x: w * 0.5 - r, y: h * 0.45 - r, width: r * 2, height: r * 2)),
                       with: .color(accent.opacity(0.12 / Double(i))), lineWidth: 1)
        }
    }

    // MARK: Cherry Blossom — a branch with five-petal flowers

    private func flower(at p: CGPoint, radius r: CGFloat, color: Color, centre: Color) {
        for k in 0..<5 {
            let a: CGFloat = CGFloat(k) * 2 * .pi / 5
            let dx: CGFloat = cos(a) * r * 0.55
            let dy: CGFloat = sin(a) * r * 0.55
            let c = CGPoint(x: p.x + dx, y: p.y + dy)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - r * 0.48, y: c.y - r * 0.48, width: r * 0.96, height: r * 0.96)), with: .color(color))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 0.18, y: p.y - r * 0.18, width: r * 0.36, height: r * 0.36)), with: .color(centre))
    }

    func blossom() {
        var branch = Path()
        branch.move(to: CGPoint(x: w + 10, y: h * 0.08))
        branch.addCurve(to: CGPoint(x: w * 0.58, y: h * 0.26), control1: CGPoint(x: w * 0.86, y: h * 0.02), control2: CGPoint(x: w * 0.7, y: h * 0.3))
        branch.move(to: CGPoint(x: w * 0.8, y: h * 0.1))
        branch.addQuadCurve(to: CGPoint(x: w * 0.74, y: h * 0.0), control: CGPoint(x: w * 0.76, y: h * 0.07))
        ctx.stroke(branch, with: .color(ink.opacity(0.6)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        let spots: [(CGFloat, CGFloat, CGFloat)] = [(0.95, 0.07, 16), (0.86, 0.1, 13), (0.78, 0.16, 18), (0.7, 0.2, 12), (0.63, 0.25, 15), (0.82, 0.04, 11), (0.74, 0.02, 10)]
        for s in spots { flower(at: CGPoint(x: w * s.0, y: h * s.1), radius: s.2, color: accent.opacity(0.45), centre: wave.last!.opacity(0.8)) }
        var rng = SeededRandom(9)
        for _ in 0..<12 {
            flower(at: CGPoint(x: rng.range(0, Double(w) * 0.4), y: rng.range(Double(h) * 0.6, Double(h))), radius: CGFloat(rng.range(5, 9)), color: ink.opacity(0.35), centre: .clear)
        }
    }

    // MARK: Golden Hour — sun rays from the top corner

    func rays() {
        let origin = CGPoint(x: w * 0.92, y: -h * 0.05)
        for i in 0..<14 {
            let a: CGFloat = .pi * 0.5 + CGFloat(i) * 0.075
            let reach: CGFloat = w * 1.4
            let p1 = CGPoint(x: origin.x + cos(a - 0.018) * reach, y: origin.y + sin(a - 0.018) * reach)
            let p2 = CGPoint(x: origin.x + cos(a + 0.018) * reach, y: origin.y + sin(a + 0.018) * reach)
            var ray = Path()
            ray.move(to: origin)
            ray.addLine(to: p1)
            ray.addLine(to: p2)
            ray.closeSubpath()
            ctx.fill(ray, with: .radialGradient(Gradient(colors: [ink.opacity(0.4), ink.opacity(0)]), center: origin, startRadius: 0, endRadius: w))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: origin.x - 90, y: origin.y - 90, width: 180, height: 180)),
                 with: .radialGradient(Gradient(colors: [wave.last!.opacity(0.7), wave.last!.opacity(0)]), center: origin, startRadius: 0, endRadius: 90))
    }

    // MARK: Alpine — layered mountain ridges

    func mountains() {
        var rng = SeededRandom(13)
        for layer in 0..<3 {
            var ridge = Path()
            let base = h * (0.66 + CGFloat(layer) * 0.1)
            ridge.move(to: CGPoint(x: 0, y: h))
            ridge.addLine(to: CGPoint(x: 0, y: base))
            var x: CGFloat = 0
            while x < w {
                let peakX = x + CGFloat(rng.range(80, 180))
                let peakY = base - CGFloat(rng.range(40, 140)) * (1 - CGFloat(layer) * 0.25)
                ridge.addLine(to: CGPoint(x: peakX, y: peakY))
                x = peakX + CGFloat(rng.range(60, 160))
                ridge.addLine(to: CGPoint(x: x, y: base - CGFloat(rng.range(0, 30))))
            }
            ridge.addLine(to: CGPoint(x: w, y: h))
            ridge.closeSubpath()
            ctx.fill(ridge, with: .color(ink.opacity(0.18 + Double(layer) * 0.14)))
        }
    }

    // MARK: Desert — rolling dunes and a bloom

    func dunes() {
        for i in 0..<3 {
            var dune = Path()
            let base = h * (0.74 + CGFloat(i) * 0.08)
            dune.move(to: CGPoint(x: 0, y: h))
            dune.addLine(to: CGPoint(x: 0, y: base))
            dune.addCurve(to: CGPoint(x: w, y: base - 30 + CGFloat(i) * 20),
                          control1: CGPoint(x: w * (0.3 + CGFloat(i) * 0.1), y: base - 90),
                          control2: CGPoint(x: w * 0.6, y: base + 40))
            dune.addLine(to: CGPoint(x: w, y: h))
            dune.closeSubpath()
            ctx.fill(dune, with: .color((i == 1 ? accent : ink).opacity(0.16 + Double(i) * 0.08)))
        }
        let sunC = CGPoint(x: w * 0.8, y: h * 0.2)
        let sunR: CGFloat = 70
        ctx.fill(Path(ellipseIn: CGRect(x: sunC.x - sunR * 2, y: sunC.y - sunR * 2, width: sunR * 4, height: sunR * 4)),
                 with: .radialGradient(Gradient(colors: [wave.last!.opacity(0.35), wave.last!.opacity(0)]), center: sunC, startRadius: sunR * 0.6, endRadius: sunR * 2))
        ctx.fill(Path(ellipseIn: CGRect(x: sunC.x - sunR, y: sunC.y - sunR, width: sunR * 2, height: sunR * 2)),
                 with: .radialGradient(Gradient(colors: [wave.last!.opacity(0.55), wave.first!.opacity(0.25)]), center: sunC, startRadius: 0, endRadius: sunR))
        // A small cactus bloom
        var cactus = Path()
        let cx = w * 0.84, cb = h * 0.8
        cactus.addRoundedRect(in: CGRect(x: cx - 9, y: cb - 110, width: 18, height: 110), cornerSize: CGSize(width: 9, height: 9))
        cactus.addRoundedRect(in: CGRect(x: cx - 38, y: cb - 78, width: 14, height: 44), cornerSize: CGSize(width: 7, height: 7))
        cactus.addRoundedRect(in: CGRect(x: cx - 38, y: cb - 42, width: 34, height: 12), cornerSize: CGSize(width: 6, height: 6))
        cactus.addRoundedRect(in: CGRect(x: cx + 22, y: cb - 92, width: 14, height: 40), cornerSize: CGSize(width: 7, height: 7))
        cactus.addRoundedRect(in: CGRect(x: cx + 4, y: cb - 60, width: 32, height: 12), cornerSize: CGSize(width: 6, height: 6))
        ctx.fill(cactus, with: .color(ink.opacity(0.4)))
        ctx.fill(Path(ellipseIn: CGRect(x: cx - 7, y: cb - 122, width: 14, height: 14)), with: .color(accent.opacity(0.7)))
    }

    // MARK: Wildflower Meadow — pastel flowers among grass

    func meadow() {
        var rng = SeededRandom(17)
        let count = Int(w / 14)
        for _ in 0..<count {
            let x = rng.range(0, Double(w))
            let height = rng.range(Double(h) * 0.05, Double(h) * 0.2)
            var blade = Path()
            blade.move(to: CGPoint(x: x, y: Double(h) + 2))
            blade.addQuadCurve(to: CGPoint(x: x + rng.range(-14, 14), y: Double(h) - height), control: CGPoint(x: x + rng.range(-6, 6), y: Double(h) - height * 0.5))
            ctx.stroke(blade, with: .color(accent.opacity(0.45)), lineWidth: 1.2)
        }
        for i in 0..<22 {
            let x = rng.range(0, Double(w)), y = rng.range(Double(h) * 0.78, Double(h) * 0.97)
            flower(at: CGPoint(x: x, y: y), radius: CGFloat(rng.range(5, 10)), color: wave[i % wave.count].opacity(0.75), centre: Color(hex: 0xF5D78E))
        }
        for i in 0..<8 {
            let x = rng.range(Double(w) * 0.6, Double(w)), y = rng.range(0, Double(h) * 0.25)
            flower(at: CGPoint(x: x, y: y), radius: CGFloat(rng.range(4, 7)), color: wave[i % wave.count].opacity(0.4), centre: .clear)
        }
    }

    // MARK: Minimal Linen — a fine woven texture

    func linen() {
        var path = Path()
        var y: CGFloat = 0
        while y < h { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y)); y += 3 }
        ctx.stroke(path, with: .color(ink.opacity(0.18)), lineWidth: 0.5)
        var v = Path()
        var x: CGFloat = 0
        while x < w { v.move(to: CGPoint(x: x, y: 0)); v.addLine(to: CGPoint(x: x, y: h)); x += 4 }
        ctx.stroke(v, with: .color(ink.opacity(0.10)), lineWidth: 0.5)
    }

    // MARK: Aurora — flowing ribbons of light

    func aurora() {
        var c = ctx
        c.addFilter(.blur(radius: 38))
        for i in 0..<3 {
            var ribbon = Path()
            let base = h * (0.18 + CGFloat(i) * 0.12)
            ribbon.move(to: CGPoint(x: -40, y: base))
            ribbon.addCurve(to: CGPoint(x: w + 40, y: base - 40 + CGFloat(i) * 30),
                            control1: CGPoint(x: w * 0.3, y: base - 120),
                            control2: CGPoint(x: w * 0.65, y: base + 110))
            c.stroke(ribbon, with: .color(wave[i % wave.count].opacity(0.75)), style: StrokeStyle(lineWidth: 60 - CGFloat(i) * 12, lineCap: .round))
        }
        var rng = SeededRandom(23)
        for _ in 0..<40 {
            let x = rng.range(0, Double(w)), y = rng.range(0, Double(h) * 0.6)
            let r = rng.range(0.8, 2)
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(Color.white.opacity(scheme == .dark ? 0.5 : 0.25)))
        }
    }

    // MARK: Espresso — curling steam and scattered beans

    func steam() {
        for i in 0..<3 {
            var s = Path()
            let x = w * 0.82 + CGFloat(i) * 22
            s.move(to: CGPoint(x: x, y: h * 0.62))
            s.addCurve(to: CGPoint(x: x + 10, y: h * 0.28), control1: CGPoint(x: x - 40, y: h * 0.5), control2: CGPoint(x: x + 50, y: h * 0.4))
            s.addCurve(to: CGPoint(x: x - 4, y: h * 0.08), control1: CGPoint(x: x - 30, y: h * 0.2), control2: CGPoint(x: x + 20, y: h * 0.14))
            ctx.stroke(s, with: .color(ink.opacity(0.45 - Double(i) * 0.1)), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
        var rng = SeededRandom(29)
        for _ in 0..<16 {
            let x = rng.range(0, Double(w) * 0.32), y = rng.range(Double(h) * 0.65, Double(h))
            var t = ctx
            t.translateBy(x: x, y: y)
            t.rotate(by: .radians(rng.range(0, .pi)))
            t.fill(Path(ellipseIn: CGRect(x: -9, y: -6, width: 18, height: 12)), with: .color(accent.opacity(0.4)))
            var crease = Path()
            crease.move(to: CGPoint(x: -7, y: 0))
            crease.addQuadCurve(to: CGPoint(x: 7, y: 0), control: CGPoint(x: 0, y: 3))
            t.stroke(crease, with: .color(ink.opacity(0.6)), lineWidth: 1)
        }
    }
}
