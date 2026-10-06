import Foundation
import DreadcastKit
import DreadTerminal

/// Paints a scene as pixel art. Everything is drawn in code, so a scene fits any size:
/// a banner over `dread`, an inline panorama, or a whole terminal.
public struct ScenePainter: Sendable {
    public let scene: SceneID
    public let period: ScenePeriod
    /// Seconds of ambient motion. Loops are independent, so the scene never moves in unison.
    public let time: Double
    /// A composed frame for still output: brief accents such as lightning are posed, not timed.
    public let still: Bool
    public let moon: LunarPhase

    public init(scene: SceneID, period: ScenePeriod, time: Double = 0, still: Bool = true, moon: LunarPhase) {
        self.scene = scene
        self.period = period
        self.time = time
        self.still = still
        self.moon = moon
    }

    public func paint(width: Int, height: Int) -> Raster {
        var canvas = SceneCanvas(width: width, height: height, time: time, period: period, still: still, moon: moon)
        switch scene {
        case .asteroid: canvas.asteroidWatch()
        case .deepTrouble: canvas.deepTrouble()
        case .aiUprising: canvas.aiUprising()
        case .solarTantrum: canvas.solarTantrum()
        case .fallout: canvas.falloutOutlook()
        case .superstorm: canvas.superstorm()
        case .clearForNow: canvas.clearForNow()
        case .uap: canvas.uapInvasion()
        }
        return canvas.raster
    }
}

/// Shared colors. Scene families follow the brand palette; other shades derive from them.
enum Ink {
    static let lamp: UInt32 = 0xFFCC9F
    static let lampHot: UInt32 = 0xFFE6C4
    static let porcelain: UInt32 = 0xEEF0F5
    static let midnight: UInt32 = 0x10192D
    static let night: UInt32 = 0x080D1A
}

struct SceneCanvas {
    var raster: Raster
    let w: Int
    let h: Int
    let t: Double
    let period: ScenePeriod
    let still: Bool
    let moon: LunarPhase
    /// Pixels per unit of a 32-pixel-tall reference panorama.
    let u: Double

    init(width: Int, height: Int, time: Double, period: ScenePeriod, still: Bool, moon: LunarPhase) {
        raster = Raster(width: width, height: height)
        w = raster.width
        h = raster.height
        t = time
        self.period = period
        self.still = still
        self.moon = moon
        u = Double(raster.height) / 32
    }

    // MARK: Geometry helpers

    func X(_ fraction: Double) -> Double { fraction * Double(w) }
    func Y(_ fraction: Double) -> Double { fraction * Double(h) }
    /// A length in reference units, scaled to this canvas and never below `minimum` pixels.
    func n(_ units: Double, minimum: Int = 1) -> Int { max(minimum, Int((units * u).rounded())) }
    func hash(_ x: Int, _ y: Int, _ seed: Int = 0) -> Double { PixelNoise.hash(x, y, seed) }
    var isNight: Bool { period == .night }
    var isEvening: Bool { period == .dusk || period == .night }

    /// A slow loop between 0 and 1 with the given period in seconds and phase offset.
    func loop(_ seconds: Double, offset: Double = 0) -> Double {
        let value = (t / seconds + offset).truncatingRemainder(dividingBy: 1)
        return value < 0 ? value + 1 : value
    }

    func wave(_ seconds: Double, offset: Double = 0) -> Double { sin((t / seconds + offset) * 2 * .pi) }

    // MARK: Sky

    static func sky(_ period: ScenePeriod) -> [UInt32] {
        switch period {
        case .dawn: [0x262A5C, 0x3B3C7B, 0x655397, 0xA06A9C, 0xDB8988, 0xFDB487]
        case .day: [0x2A5DB6, 0x3570C5, 0x4585D2, 0x5B9BDD, 0x7AB3E7, 0xA5CDF0]
        case .dusk: [0x161E47, 0x272A5E, 0x493771, 0x854876, 0xCD625E, 0xFC985B]
        case .night: [0x050A1A, 0x081028, 0x0C1733, 0x111F40, 0x172A50, 0x203761]
        }
    }

    mutating func sky(_ stops: [UInt32], to bottom: Int) {
        var fine: [UInt32] = []
        for (i, stop) in stops.enumerated() {
            fine.append(stop)
            if i + 1 < stops.count { fine.append(Raster.mix(stop, stops[i + 1], 0.5)) }
        }
        raster.ditheredGradient(fine, top: 0, bottom: bottom, softness: 0.3)
    }

    mutating func stars(until bottom: Int, density: Double = 0.014, seed: Int = 3) {
        guard bottom > 0 else { return }
        for y in 0..<min(bottom, h) {
            let fade = 1 - Double(y) / Double(bottom)
            for x in 0..<w {
                let r = hash(x, y, seed)
                guard r < density * fade else { continue }
                let b = hash(x, y, seed + 1)
                var color: UInt32 = b > 0.78 ? Ink.porcelain : b > 0.42 ? 0xA9B6D0 : 0x66789E
                if !still, b > 0.55, sin(t * (0.7 + b * 1.6) + r * 4000) < -0.7 { color = 0x4A5A80 }
                raster.plot(x, y, color)
            }
        }
    }

    mutating func sun(x: Double, y: Double, radius r: Double, core: UInt32, glow: UInt32, reach: Double = 3.4) {
        raster.glow(cx: x, cy: y, radius: r * reach, color: glow, strength: 0.55, rings: 3)
        raster.fillCircle(cx: x, cy: y, radius: r, color: core)
    }

    /// The moon in tonight's real phase, lit from the right while waxing.
    mutating func moonDisc(x: Double, y: Double, radius r: Double) {
        let k = moon.illumination
        raster.glow(cx: x, cy: y, radius: r * 2.8, color: 0x8FA3CC, strength: 0.15 + 0.25 * k, rings: 3)
        let minY = Int(floor(y - r)), maxY = Int(ceil(y + r)), minX = Int(floor(x - r)), maxX = Int(ceil(x + r))
        for py in minY...maxY {
            for px in minX...maxX {
                let dx = Double(px) + 0.5 - x, dy = Double(py) + 0.5 - y
                guard dx * dx + dy * dy <= r * r else { continue }
                let half = max(0, r * r - dy * dy).squareRoot()
                let edge = half * (1 - 2 * k)
                let lit = moon.isWaxing ? dx >= edge : dx <= -edge
                guard lit else {
                    raster.blend(x: px, y: py, color: 0x2A3452, alpha: 0.55)
                    continue
                }
                raster.plot(px, py, r >= 3 && hash(px, py, 41) < 0.18 ? 0xCFCBC0 : 0xF2EFE2)
            }
        }
    }

    /// A flat-bottomed pixel cloud in three tones.
    mutating func cloud(x: Double, y: Double, width cw: Double, height ch: Double,
                        light: UInt32, mid: UInt32, shade: UInt32, seed: Int) {
        guard cw >= 2, ch >= 1 else { return }
        let bottom = y + ch / 2
        let count = max(2, Int(cw / max(1, ch * 1.1)))
        var bumps: [(x: Double, y: Double, r: Double)] = []
        for i in 0..<count {
            let f = (Double(i) + 0.5) / Double(count)
            let taper = 1 - 0.45 * abs(f - 0.5) * 2
            let r = ch * (0.42 + 0.3 * hash(i, seed, 5)) * taper + 0.6
            bumps.append((x - cw / 2 + f * cw, bottom - r * 0.75, r))
        }
        let minX = Int(floor(x - cw / 2 - ch)), maxX = Int(ceil(x + cw / 2 + ch))
        let minY = Int(floor(bottom - ch * 1.6)), maxY = Int(ceil(bottom))
        func inside(_ px: Int, _ py: Int) -> Bool {
            let cy = Double(py) + 0.5
            guard cy < bottom else { return false }
            let cx = Double(px) + 0.5
            if cx >= x - cw / 2 && cx <= x + cw / 2 && cy >= bottom - ch * 0.42 { return true }
            for b in bumps where (cx - b.x) * (cx - b.x) + (cy - b.y) * (cy - b.y) <= b.r * b.r { return true }
            return false
        }
        for py in minY...maxY {
            for px in minX...maxX where inside(px, py) {
                let color: UInt32
                if Double(py) + 0.5 >= bottom - max(1, ch * 0.28) { color = shade }
                else if !inside(px, py - 1) { color = light }
                else { color = mid }
                raster.plot(px, py, color)
            }
        }
    }

    /// Clouds drifting slowly across the sky.
    mutating func driftingClouds(count: Int, top: Double, bottom: Double, size: Double,
                                 light: UInt32, mid: UInt32, shade: UInt32, seed: Int, speed: Double = 1) {
        for i in 0..<count {
            let cw = Double(n(size * (0.8 + 0.6 * hash(i, seed, 1)), minimum: 4))
            let ch = max(1.5, cw * 0.28)
            let travel = Double(w) + cw * 2
            let start = hash(i, seed, 2) * travel
            let x = (start + t * speed * u * (0.25 + 0.2 * hash(i, seed, 3))).truncatingRemainder(dividingBy: travel) - cw
            let y = Y(top + (bottom - top) * hash(i, seed, 4))
            cloud(x: x, y: y, width: cw, height: ch, light: light, mid: mid, shade: shade, seed: seed + i)
        }
    }

    // MARK: Ground and water

    /// Water that mirrors the sky above it, with drifting highlights.
    mutating func water(from top: Int, to bottom: Int, sky: [UInt32], tint: UInt32, shimmer: UInt32, seed: Int = 9) {
        guard bottom > top else { return }
        for y in max(0, top)..<min(h, bottom) {
            let depth = Double(y - top) / Double(max(1, bottom - top))
            let skyIndex = min(sky.count - 1, max(0, sky.count - 1 - Int(depth * Double(sky.count))))
            let base = Raster.mix(sky[skyIndex], tint, 0.45 + 0.35 * depth)
            for x in 0..<w { raster[x, y] = base }
            // Short highlight dashes, sparser and slower further away.
            let rowSpeed = (0.6 + depth * 1.8) * u
            for x in 0..<w {
                let shifted = Int(floor((Double(x) + t * rowSpeed) / Double(max(2, n(4)))))
                if hash(shifted, y, seed) > 0.93 - depth * 0.05 {
                    raster.blend(x: x, y: y, color: shimmer, alpha: 0.3 + 0.15 * depth)
                }
            }
        }
    }

    /// A vertical shimmering reflection of a light, such as the sun, moon or a window.
    mutating func reflection(x center: Double, from top: Int, to bottom: Int, width rw: Double, color: UInt32, strength: Double = 0.9, seed: Int = 13) {
        guard bottom > top else { return }
        for y in max(0, top)..<min(h, bottom) {
            let depth = Double(y - top) / Double(max(1, bottom - top))
            let spread: Double = rw * (0.6 + depth * 1.2)
            let wobble: Double = still ? 0 : sin(t * 1.7 + Double(y) * 0.9) * 0.6 * u
            let flicker = Int(t * 2)
            for px in Int(floor(center - spread))...Int(ceil(center + spread)) {
                let offset: Double = Double(px) + 0.5 - center - wobble
                let d = abs(offset) / max(0.5, spread)
                guard d < 1 else { continue }
                let broken: Double = hash(px / 2 + flicker, y, seed) > 0.35 ? 1.0 : 0.35
                let alpha: Double = (1 - d) * strength * broken * (1 - depth * 0.5)
                raster.blendStepped(px, y, color, alpha: alpha)
            }
        }
    }

    // MARK: Buildings

    struct Building {
        var x: Int
        var width: Int
        var height: Int
        var style: Int
    }

    /// A row of buildings across the canvas.
    func skyline(seed: Int, minWidth: Double, maxWidth: Double, minHeight: Double, maxHeight: Double,
                 gap: Double = 0.2, from: Int = 0, to: Int? = nil) -> [Building] {
        var result: [Building] = []
        var x = from - n(1)
        var i = 0
        let end = to ?? w
        while x < end {
            let bw = n(minWidth + (maxWidth - minWidth) * hash(i, seed, 1), minimum: 2)
            let bh = max(1, Int((minHeight + (maxHeight - minHeight) * pow(hash(i, seed, 2), 1.4)) * Double(h)))
            result.append(Building(x: x, width: bw, height: bh, style: Int(hash(i, seed, 3) * 6)))
            x += bw + (hash(i, seed, 4) < gap ? n(1) : 0)
            i += 1
        }
        return result
    }

    struct WindowLights {
        var lit: Double
        var colors: [UInt32]
        var dark: UInt32?
    }

    mutating func drawBuildings(_ buildings: [Building], base: Int, body: UInt32, roofline: UInt32? = nil,
                                windows: WindowLights? = nil, seed: Int) {
        for b in buildings {
            let top = base - b.height
            raster.fillRect(x: b.x, y: top, width: b.width, height: b.height + 1, color: body)
            // Rooftop details at larger sizes: antennas, setbacks and water tanks.
            if b.height > n(6) {
                switch b.style {
                case 0:
                    let ax = b.x + b.width / 2
                    for y in (top - n(3))..<top { raster.plot(ax, y, body) }
                case 1 where b.width >= 4:
                    raster.fillRect(x: b.x + 1, y: top - n(2), width: b.width - 2, height: n(2), color: body)
                case 2 where b.width >= 5:
                    raster.fillRect(x: b.x + b.width / 2 - 1, y: top - n(2), width: n(2, minimum: 2), height: n(1), color: body)
                    raster.plot(b.x + b.width / 2 - 1, top - 1, body)
                    raster.plot(b.x + b.width / 2 + n(1), top - 1, body)
                default: break
                }
            }
            if let roofline { raster.fillRect(x: b.x, y: top, width: b.width, height: 1, color: roofline) }
            guard let windows, b.width >= 3, b.height >= 3 else { continue }
            var wy = top + 1 + (b.style % 2)
            while wy < base - 1 {
                var wx = b.x + 1
                while wx < b.x + b.width - 1 {
                    let r = hash(wx, wy, seed)
                    if r < windows.lit {
                        let color = windows.colors[Int(hash(wx, wy, seed + 1) * Double(windows.colors.count)) % windows.colors.count]
                        raster.plot(wx, wy, color)
                    } else if let dark = windows.dark {
                        raster.plot(wx, wy, dark)
                    }
                    wx += 2
                }
                wy += 2
            }
        }
    }

    /// The Dreadcast signature: one ordinary, warm window near the corner of the scene.
    mutating func lampWindow(x: Int, y: Int, size: Int = 0) {
        let s = size > 0 ? size : n(1.4, minimum: 1)
        raster.glow(cx: Double(x) + Double(s) / 2, cy: Double(y) + Double(s) / 2, radius: Double(s) * 2.6 + 1.5,
                    color: Ink.lamp, strength: 0.35, rings: 3)
        raster.fillRect(x: x, y: y, width: s, height: s, color: Ink.lamp)
        if s >= 3 {
            // A desk lamp's shade inside the window.
            raster.plot(x + s / 2, y + s - 1, 0xC98D5E)
            raster.plot(x + s - 1, y, Ink.lampHot)
        }
    }

    /// A dark apartment block at the right edge with the lamp lit.
    mutating func apartment(rightInset: Int = 0, base: Int, width bw: Int, height bh: Int, body: UInt32, dim: UInt32) {
        let x = w - rightInset - bw
        let top = base - bh
        raster.fillRect(x: x, y: top, width: bw, height: h - top, color: body)
        raster.fillRect(x: x - 1, y: top - 1, width: bw + 2, height: 1, color: Raster.mix(body, 0x000000, 0.3))
        var wy = top + n(2)
        var row = 0
        while wy < base - n(2) {
            var wx = x + n(1)
            var column = 0
            while wx < x + bw - n(1) {
                if hash(column, row, 77) < 0.35 { raster.fillRect(x: wx, y: wy, width: n(1.4), height: n(1.4), color: dim) }
                wx += n(3, minimum: 2)
                column += 1
            }
            wy += n(3, minimum: 2)
            row += 1
        }
        lampWindow(x: x + n(1), y: top + n(2))
    }

    /// Building tones for each time of day: far, middle, near.
    var cityTones: (far: UInt32, mid: UInt32, near: UInt32, windows: WindowLights) {
        switch period {
        case .dawn: (0x5E5384, 0x37315A, 0x1D1A35, WindowLights(lit: 0.22, colors: [Ink.lamp, 0xF2B07E, 0xFFE0B0], dark: nil))
        case .day: (0x8AA6C6, 0x5B7596, 0x2D3C55, WindowLights(lit: 0.3, colors: [0xC6D9EA, 0xA9C2DA], dark: nil))
        case .dusk: (0x553C66, 0x30254A, 0x191530, WindowLights(lit: 0.42, colors: [Ink.lamp, 0xF2B07E, 0xFFE0B0, 0xE89A6A], dark: nil))
        case .night: (0x171E3B, 0x10152E, 0x090D1C, WindowLights(lit: 0.55, colors: [Ink.lamp, 0xF2B07E, 0xFFE0B0, 0xE8A06A, 0x9FB8D8], dark: nil))
        }
    }

    // MARK: Small shapes

    /// A line of filled circles, for limbs, stems and beams.
    mutating func stroke(_ points: [(x: Double, y: Double)], radius: (Double) -> Double, color: (Double) -> UInt32) {
        guard points.count >= 2 else { return }
        var length = 0.0
        var lengths = [0.0]
        for i in 1..<points.count {
            length += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
            lengths.append(length)
        }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let segment = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) * 2)))
            for j in 0...segment {
                let f = Double(j) / Double(segment)
                let s = (lengths[i - 1] + (lengths[i] - lengths[i - 1]) * f) / max(1e-9, length)
                raster.fillCircle(cx: a.x + (b.x - a.x) * f, cy: a.y + (b.y - a.y) * f, radius: radius(s), color: color(s))
            }
        }
    }

    mutating func polygon(_ points: [(x: Double, y: Double)], color: UInt32, alpha: Double = 1) {
        raster.fillPolygons([points], color: color, alpha: alpha)
    }

    /// A rolling hill line: the y of the ground at each x.
    func hills(base: Double, amplitude: Double, seed: Int, frequency: Double = 1) -> [Double] {
        let a = hash(1, seed, 1) * 6, b = hash(2, seed, 1) * 6
        return (0..<w).map { x in
            let f = Double(x) / Double(w) * frequency
            return base - amplitude * (0.6 * sin(f * 5.1 + a) + 0.4 * sin(f * 11.3 + b))
        }
    }

    mutating func fillBelow(_ line: [Double], color: UInt32, to bottom: Int? = nil) {
        let end = bottom ?? h
        for x in 0..<min(w, line.count) {
            let top = Int(line[x].rounded())
            for y in max(0, top)..<end { raster[x, y] = color }
        }
    }

    /// A simple tree: a trunk and a rounded crown, bending with the wind.
    mutating func tree(x: Double, base: Double, height th: Double, crown: UInt32, trunk: UInt32, bend: Double = 0, light: UInt32? = nil) {
        let crownR = max(1, th * 0.38)
        let topY = base - th + crownR
        for y in Int(topY)..<Int(base) {
            let f = (base - Double(y)) / th
            raster.plot(Int((x + bend * f * f).rounded()), y, trunk)
        }
        raster.fillEllipse(cx: x + bend, cy: topY, rx: crownR * 1.05, ry: crownR, color: crown)
        if let light, crownR >= 2 {
            raster.fillEllipse(cx: x + bend - crownR * 0.3, cy: topY - crownR * 0.3, rx: crownR * 0.5, ry: crownR * 0.45, color: light)
        }
    }
}
