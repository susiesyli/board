import SwiftUI
import AppKit

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Uniform in -1..<1
    mutating func signed() -> Float { Float(next() >> 40) / 8_388_608 - 1 }
}

// MARK: - Galvanized texture

/// Procedurally generated galvanized steel, like a sheet propped against a studio wall:
/// broad cloudy patches, faint zinc "spangle" crystals, a few rolling marks, fine grain.
/// Every layer wraps around, so the texture tiles seamlessly.
enum Galvanized {
    static let texture: CGImage = make(width: 1024, height: 1600, seed: 0x6A1F_2026)

    static func make(width w: Int, height h: Int, seed: UInt64) -> CGImage {
        var rng = SeededRNG(state: seed)

        let clouds = valueNoise(w, h, cellsX: 4, cellsY: 6, rng: &rng)
        let mottle = valueNoise(w, h, cellsX: 16, cellsY: 25, rng: &rng)
        let (crystal, seams) = crystals(w, h, cell: 64, rng: &rng)
        let rolling = normalized(blurRows((0..<(w * h)).map { _ in rng.signed() }, w, h, radius: 60))

        var px = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let v = 0.60
                + clouds[i] * 0.065
                + mottle[i] * 0.025
                + crystal[i] * 0.009
                - seams[i] * 0.004
                + rolling[i] * 0.006
                + rng.signed() * 0.007
            px[i] = UInt8(max(0, min(1, v)) * 255)
        }

        let provider = CGDataProvider(data: Data(px) as CFData)!
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )!
    }

    /// Smooth periodic value noise in roughly -1...1.
    private static func valueNoise(_ w: Int, _ h: Int, cellsX: Int, cellsY: Int, rng: inout SeededRNG) -> [Float] {
        let grid = (0..<(cellsX * cellsY)).map { _ in rng.signed() }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let fy = Float(y) / Float(h) * Float(cellsY)
            let y0 = Int(fy) % cellsY, y1 = (y0 + 1) % cellsY
            var ty = fy - Float(Int(fy))
            ty = ty * ty * (3 - 2 * ty)
            for x in 0..<w {
                let fx = Float(x) / Float(w) * Float(cellsX)
                let x0 = Int(fx) % cellsX, x1 = (x0 + 1) % cellsX
                var tx = fx - Float(Int(fx))
                tx = tx * tx * (3 - 2 * tx)
                let top = grid[y0 * cellsX + x0] + (grid[y0 * cellsX + x1] - grid[y0 * cellsX + x0]) * tx
                let bottom = grid[y1 * cellsX + x0] + (grid[y1 * cellsX + x1] - grid[y1 * cellsX + x0]) * tx
                out[y * w + x] = top + (bottom - top) * ty
            }
        }
        return out
    }

    /// Voronoi crystals: each cell gets its own tone, with faint seams where cells meet.
    private static func crystals(_ w: Int, _ h: Int, cell: Int, rng: inout SeededRNG) -> (tone: [Float], seam: [Float]) {
        let cx = w / cell, cy = h / cell
        var ox = [Float](), oy = [Float](), tones = [Float]()
        for _ in 0..<(cx * cy) {
            ox.append(Float(rng.unit()))
            oy.append(Float(rng.unit()))
            tones.append(rng.signed())
        }
        var tone = [Float](repeating: 0, count: w * h)
        var seam = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let gy = y / cell
            for x in 0..<w {
                let gx = x / cell
                var d1 = Float.greatestFiniteMagnitude, d2 = d1, best = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = gx + dx, ny = gy + dy
                        let k = ((ny % cy + cy) % cy) * cx + ((nx % cx + cx) % cx)
                        let px = (Float(nx) + ox[k]) * Float(cell) - Float(x)
                        let py = (Float(ny) + oy[k]) * Float(cell) - Float(y)
                        let d = px * px + py * py
                        if d < d1 { d2 = d1; d1 = d; best = k } else if d < d2 { d2 = d }
                    }
                }
                let i = y * w + x
                tone[i] = tones[best]
                seam[i] = max(0, 1 - (d2.squareRoot() - d1.squareRoot()) / 2.5)
            }
        }
        return (tone, seam)
    }

    /// Horizontal box blur, wrapping at the row ends.
    private static func blurRows(_ src: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        var out = [Float](repeating: 0, count: src.count)
        let norm = 1 / Float(2 * r + 1)
        src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h {
                    let row = y * w
                    var sum: Float = 0
                    for k in -r...r { sum += s[row + ((k % w) + w) % w] }
                    for x in 0..<w {
                        o[row + x] = sum * norm
                        sum += s[row + (x + r + 1) % w] - s[row + ((x - r) % w + w) % w]
                    }
                }
            }
        }
        return out
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let mean = v.reduce(0, +) / Float(v.count)
        let variance = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(v.count)
        let sd = max(variance.squareRoot(), 1e-6)
        return v.map { ($0 - mean) / sd }
    }
}

// MARK: - Surface

struct AluminumSurface: View {
    var scratches = true

    var body: some View {
        ZStack {
            Image(decorative: Galvanized.texture, scale: 2)
                .resizable(resizingMode: .tile)
            // Zinc has a cool, slightly blue cast.
            Color(red: 0.42, green: 0.50, blue: 0.60).opacity(0.16)
            // Daylight falling from above, washing out the top of the sheet.
            LinearGradient(stops: [
                .init(color: .white.opacity(0.30), location: 0),
                .init(color: .white.opacity(0.10), location: 0.3),
                .init(color: .clear, location: 0.6),
                .init(color: .black.opacity(0.10), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [.white.opacity(0.22), .clear],
                center: UnitPoint(x: 0.3, y: 0), startRadius: 0, endRadius: 520
            )
            if scratches { Scratches() }
        }
        .allowsHitTesting(false)
    }
}

/// Faint hairline scratches at random angles — the "lived-in" detail of a real metal sheet.
struct Scratches: View {
    var seed: UInt64 = 7

    var body: some View {
        Canvas { ctx, size in
            var rng = SeededRNG(state: seed)
            let count = Int(size.width * size.height / 14000)
            for _ in 0..<count {
                let x = rng.unit() * size.width
                let y = rng.unit() * size.height
                let len = 12 + pow(rng.unit(), 2) * 150
                var angle = (rng.unit() - 0.5) * 0.35
                if rng.unit() < 0.3 { angle += (rng.unit() - 0.5) * 2.6 }
                var p = Path()
                p.move(to: CGPoint(x: x, y: y))
                // A slight bow makes them look hand-made rather than ruled.
                let end = CGPoint(x: x + cos(angle) * len, y: y + sin(angle) * len)
                let mid = CGPoint(x: (x + end.x) / 2, y: (y + end.y) / 2 + (rng.unit() - 0.5) * len * 0.08)
                p.addQuadCurve(to: end, control: mid)
                let light = rng.unit() < 0.65
                let color: Color = light ? .white.opacity(0.08 + rng.unit() * 0.12) : .black.opacity(0.03 + rng.unit() * 0.05)
                ctx.stroke(p, with: .color(color), lineWidth: 0.35 + rng.unit() * 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The cut edge of the sheet. A real sheet has no drawn border — just the faintest
/// line where the metal ends, so it doesn't dissolve into a light background.
struct BoardRim: View {
    var radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            .allowsHitTesting(false)
    }
}

/// A round, matte-steel fridge magnet (used by the app icon).
struct Magnet: View {
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(
                colors: [Color(white: 0.84), Color(white: 0.60)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
            Circle().fill(RadialGradient(
                colors: [.white.opacity(0.75), .white.opacity(0)],
                center: UnitPoint(x: 0.34, y: 0.30), startRadius: 0, endRadius: size * 0.48
            ))
            Circle().strokeBorder(
                LinearGradient(colors: [.white.opacity(0.85), .black.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: max(0.6, size * 0.04)
            )
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.38), radius: size * 0.06, x: size * 0.03, y: size * 0.07)
        .shadow(color: .black.opacity(0.16), radius: size * 0.2, x: size * 0.06, y: size * 0.16)
        .allowsHitTesting(false)
    }
}

// MARK: - Raw mouse tracking

/// An AppKit view that reports drags in *screen* coordinates. Used for anything that moves
/// or resizes a window, where SwiftUI's local coordinates would shift under the gesture.
struct MouseTracker: NSViewRepresentable {
    var onDown: () -> Void = {}
    var onDrag: (CGSize) -> Void = { _ in }
    var onUp: (_ moved: Bool) -> Void = { _ in }
    var onHover: ((Bool) -> Void)?
    /// A press that didn't turn into a drag: click count and location (top-left origin).
    var onClick: ((Int, CGPoint) -> Void)?
    /// Shown while dragging, e.g. a closed hand when moving the board.
    var dragCursor: NSCursor?
    /// Shown while the pointer is over this view, e.g. a resize arrow on the board's edges.
    var hoverCursor: NSCursor?
    /// Right-click menu, given the click location (top-left origin).
    var menu: ((CGPoint) -> NSMenu)?

    func makeNSView(context: Context) -> TrackerView {
        let v = TrackerView()
        v.parent = self
        return v
    }

    func updateNSView(_ v: TrackerView, context: Context) { v.parent = self }

    final class TrackerView: NSView {
        var parent: MouseTracker!
        private var start: NSPoint?
        private var moved = false

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) {
            parent.hoverCursor?.set()
            parent.onHover?(true)
        }

        override func mouseMoved(with event: NSEvent) { parent.hoverCursor?.set() }

        override func mouseExited(with event: NSEvent) {
            if parent.hoverCursor != nil && start == nil { NSCursor.arrow.set() }
            parent.onHover?(false)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let build = parent.menu else { return super.menu(for: event) }
            return build(convert(event.locationInWindow, from: nil))
        }

        override func mouseDown(with event: NSEvent) {
            start = NSEvent.mouseLocation
            moved = false
            parent.onDown()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let s = start else { return }
            let m = NSEvent.mouseLocation
            let d = CGSize(width: m.x - s.x, height: m.y - s.y)
            if !moved, abs(d.width) + abs(d.height) > 3 {
                moved = true
                parent.dragCursor?.push()
            }
            if moved { parent.onDrag(d) }
        }

        override func mouseUp(with event: NSEvent) {
            if moved {
                if parent.dragCursor != nil { NSCursor.pop() }
            } else {
                parent.onClick?(event.clickCount, convert(event.locationInWindow, from: nil))
            }
            parent.onUp(moved)
            start = nil
            if let hover = parent.hoverCursor {
                let inside = bounds.contains(convert(event.locationInWindow, from: nil))
                (inside ? hover : NSCursor.arrow).set()
            }
        }
    }
}
