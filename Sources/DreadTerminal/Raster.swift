import Foundation

/// An RGB image buffer used to compose maps before rendering them to the terminal.
public struct Raster: Sendable {
    public let width: Int
    public let height: Int
    /// 0xRRGGBB, row-major.
    public var pixels: [UInt32]

    public init(width: Int, height: Int, fill: UInt32 = 0) {
        self.width = max(1, width)
        self.height = max(1, height)
        pixels = [UInt32](repeating: fill, count: self.width * self.height)
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> UInt32 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    @inline(__always)
    public mutating func blend(x: Int, y: Int, color: UInt32, alpha: Double) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        if alpha >= 1 { pixels[y * width + x] = color; return }
        if alpha <= 0 { return }
        pixels[y * width + x] = Self.mix(pixels[y * width + x], color, alpha)
    }

    @inline(__always)
    public static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let x = Double((a >> shift) & 0xFF), y = Double((b >> shift) & 0xFF)
            return UInt32((x + (y - x) * t).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    /// Fills polygons with the even-odd rule. Rings are in pixel coordinates.
    public mutating func fillPolygons(_ rings: [[(x: Double, y: Double)]], color: UInt32, alpha: Double = 1) {
        struct Edge { let x0, y0, x1, y1: Double }
        var edges: [Edge] = []
        for ring in rings where ring.count >= 3 {
            for i in 0..<ring.count {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                if a.y == b.y { continue }
                edges.append(a.y < b.y ? Edge(x0: a.x, y0: a.y, x1: b.x, y1: b.y) : Edge(x0: b.x, y0: b.y, x1: a.x, y1: a.y))
            }
        }
        guard !edges.isEmpty else { return }
        // Bucket edges by their first scanline.
        var buckets = [[Int]](repeating: [], count: height)
        for (index, edge) in edges.enumerated() {
            let start = max(0, Int(ceil(edge.y0 - 0.5)))
            guard start < height, edge.y1 > 0 else { continue }
            buckets[start].append(index)
        }
        var active: [Int] = []
        var crossings: [Double] = []
        for y in 0..<height {
            let sampleY = Double(y) + 0.5
            active.append(contentsOf: buckets[y])
            active.removeAll { edges[$0].y1 <= sampleY }
            crossings.removeAll(keepingCapacity: true)
            for index in active {
                let e = edges[index]
                guard sampleY >= e.y0, sampleY < e.y1 else { continue }
                crossings.append(e.x0 + (sampleY - e.y0) * (e.x1 - e.x0) / (e.y1 - e.y0))
            }
            guard crossings.count >= 2 else { continue }
            crossings.sort()
            var i = 0
            while i + 1 < crossings.count {
                let from = max(0, Int(ceil(crossings[i] - 0.5)))
                let to = min(width - 1, Int(floor(crossings[i + 1] - 0.5)))
                if from <= to {
                    for x in from...to { blend(x: x, y: y, color: color, alpha: alpha) }
                }
                i += 2
            }
        }
    }

    /// Draws connected line segments with Bresenham's algorithm.
    public mutating func strokePolyline(_ points: [(x: Double, y: Double)], color: UInt32, alpha: Double = 1, closed: Bool = false) {
        guard points.count >= 2 else { return }
        let count = closed ? points.count : points.count - 1
        for i in 0..<count {
            line(from: points[i], to: points[(i + 1) % points.count], color: color, alpha: alpha)
        }
    }

    public mutating func line(from a: (x: Double, y: Double), to b: (x: Double, y: Double), color: UInt32, alpha: Double = 1) {
        // Skip segments entirely outside the raster.
        if (a.x < -1 && b.x < -1) || (a.y < -1 && b.y < -1) ||
            (a.x > Double(width) && b.x > Double(width)) || (a.y > Double(height) && b.y > Double(height)) { return }
        var x0 = Int(a.x.rounded(.down)), y0 = Int(a.y.rounded(.down))
        let x1 = Int(b.x.rounded(.down)), y1 = Int(b.y.rounded(.down))
        let dx = abs(x1 - x0), dy = -abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1
        var error = dx + dy
        var steps = 0
        while steps < 100_000 {
            blend(x: x0, y: y0, color: color, alpha: alpha)
            if x0 == x1 && y0 == y1 { break }
            let e2 = 2 * error
            if e2 >= dy { error += dy; x0 += sx }
            if e2 <= dx { error += dx; y0 += sy }
            steps += 1
        }
    }

    public mutating func fillCircle(cx: Double, cy: Double, radius: Double, color: UInt32, alpha: Double = 1) {
        let r2 = radius * radius
        let minY = max(0, Int(floor(cy - radius))), maxY = min(height - 1, Int(ceil(cy + radius)))
        let minX = max(0, Int(floor(cx - radius))), maxX = min(width - 1, Int(ceil(cx + radius)))
        guard minY <= maxY, minX <= maxX, cx.isFinite, cy.isFinite else { return }
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                if dx * dx + dy * dy <= r2 { blend(x: x, y: y, color: color, alpha: alpha) }
            }
        }
    }

    /// A one-pixel circle outline.
    public mutating func strokeCircle(cx: Double, cy: Double, radius: Double, color: UInt32, alpha: Double = 1) {
        guard radius > 0 else { return }
        let steps = max(16, Int(radius * 8))
        var previous: (x: Double, y: Double)?
        for i in 0...steps {
            let angle = Double(i) / Double(steps) * 2 * .pi
            let point = (x: cx + cos(angle) * radius, y: cy + sin(angle) * radius)
            if let previous { line(from: previous, to: point, color: color, alpha: alpha) }
            previous = point
        }
    }
}
