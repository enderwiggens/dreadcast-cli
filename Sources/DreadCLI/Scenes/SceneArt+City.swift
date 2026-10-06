import Foundation
import DreadTerminal

// Asteroid Watch, AI Uprising and Fallout Outlook: three skylines, three disturbances.
extension SceneCanvas {
    // MARK: Asteroid Watch

    /// A faceted asteroid approaches through broad coral trails and fine orbital lines.
    mutating func asteroidWatch() {
        let horizon = Int(Y(0.82))
        var stops = Self.sky(period)
        switch period {
        case .dusk: stops = [0x1A1638, 0x2B1F4C, 0x4C2C5E, 0x82405F, 0xBD6876, 0xF29A7C]
        case .night: stops = [0x070919, 0x0B0D23, 0x11122C, 0x171635, 0x201D40, 0x2B244C]
        default: break
        }
        sky(stops, to: horizon + 1)
        switch period {
        case .dawn:
            sun(x: X(0.24), y: Double(horizon), radius: max(1.5, 1.9 * u), core: 0xFFE2A8, glow: 0xFFB27A)
            driftingClouds(count: 3, top: 0.08, bottom: 0.45, size: 10, light: 0xF7C2A4, mid: 0xB98AA8, shade: 0x7D6494, seed: 21, speed: 0.6)
        case .day:
            sun(x: X(0.30), y: Y(0.16), radius: max(1.2, 1.3 * u), core: 0xFFF8E2, glow: 0xD4EAFA)
            driftingClouds(count: 4, top: 0.06, bottom: 0.5, size: 10, light: 0xFFFFFF, mid: 0xDCE8F4, shade: 0xA9BED6, seed: 22)
        case .dusk:
            sun(x: X(0.16), y: Double(horizon), radius: max(2, 2.5 * u), core: 0xFFB06A, glow: 0xF07C5C)
            driftingClouds(count: 3, top: 0.1, bottom: 0.4, size: 11, light: 0xF6A48A, mid: 0x9C5A78, shade: 0x5E3A62, seed: 23, speed: 0.6)
        case .night:
            stars(until: horizon - n(2), density: 0.016)
            moonDisc(x: X(0.36), y: Y(0.14), radius: max(1.2, 1.4 * u))
        }

        let spec: (x: Double, y: Double, r: Double, trail: Double, heat: Double) = switch period {
        case .dawn: (0.66, 0.20, 0.022, 0.09, 0.25)
        case .day: (0.70, 0.25, 0.062, 0.26, 0.4)
        case .dusk: (0.69, 0.31, 0.10, 0.38, 0.75)
        case .night: (0.68, 0.36, 0.14, 0.46, 1)
        }
        let r = max(0.9, Y(spec.r))
        incomingAsteroid(cx: X(spec.x), cy: Y(spec.y), r: r, trail: X(spec.trail), heat: spec.heat, horizon: horizon)

        let tones = cityTones
        let far = skyline(seed: 11, minWidth: 2, maxWidth: 5, minHeight: 0.07, maxHeight: 0.22)
        drawBuildings(far, base: horizon, body: tones.far,
                      windows: WindowLights(lit: tones.windows.lit * 0.45, colors: tones.windows.colors.map { Raster.mix($0, tones.far, 0.45) }),
                      seed: 12)
        let near = skyline(seed: 13, minWidth: 3, maxWidth: 7, minHeight: 0.035, maxHeight: 0.13, gap: 0.35)
        drawBuildings(near, base: horizon + n(1), body: tones.mid, windows: tones.windows, seed: 14)
        raster.fillRect(x: 0, y: horizon + n(1), width: w, height: h, color: tones.near)
        if isEvening {
            // The glow reaches the street below.
            raster.glow(cx: X(spec.x - 0.08), cy: Double(horizon + n(2)), radius: X(0.16), color: 0xBD6876, strength: 0.25 * spec.heat, rings: 3)
        }
        apartment(base: h, width: n(9, minimum: 6), height: Int(Y(0.30)), body: Raster.mix(tones.near, 0x000000, 0.25),
                  dim: Raster.mix(tones.mid, 0x000000, 0.1))
    }

    mutating func incomingAsteroid(cx: Double, cy: Double, r: Double, trail: Double, heat: Double, horizon: Int) {
        let dir = (x: 0.87, y: -0.49)      // toward the tail, up and to the right
        let perp = (x: 0.49, y: 0.87)

        // Fine orbital lines beside the trail.
        if r >= 1.4 {
            for (k, offset) in [-2.2, 1.8, 2.9].enumerated() {
                let length = trail * (1.05 + 0.25 * Double(k))
                let steps = Int(length * 1.5)
                for i in 0..<max(1, steps) {
                    let s = Double(i) / Double(max(1, steps))
                    let px = cx + perp.x * offset * r + dir.x * (r + s * length)
                    let py = cy + perp.y * offset * r + dir.y * (r + s * length)
                    raster.blendStepped(Int(px), Int(py), 0xE7A39A, alpha: 0.45 * (1 - s))
                }
            }
        }

        // The broad coral trail, tapering and fading with distance from the head.
        let colors: [UInt32] = [Ink.lampHot, Ink.lamp, 0xF2A88A, 0xDB8580, 0xBD6876, 0x8C5272]
        let minX = Int(cx - r * 2), maxX = Int(cx + dir.x * trail + r * 2)
        let minY = Int(cy + dir.y * trail - r * 2), maxY = Int(cy + r * 2)
        for py in stride(from: max(0, minY), through: min(h - 1, maxY), by: 1) {
            for px in stride(from: max(0, minX), through: min(w - 1, maxX), by: 1) {
                let vx = Double(px) + 0.5 - cx, vy = Double(py) + 0.5 - cy
                let s = vx * dir.x + vy * dir.y
                guard s > 0, s < trail else { continue }
                let d = vx * perp.x + vy * perp.y
                let along = s / trail
                let half = r * (1.02 - 0.62 * along)
                guard abs(d) < half else { continue }
                let core = 1 - abs(d) / half
                let ripple = still ? 1 : 0.85 + 0.15 * sin((s - t * 7 * u) / (2.2 * u))
                let alpha = pow(1 - along, 0.8) * (0.55 + 0.6 * core) * ripple
                let index = min(colors.count - 1, Int(along * Double(colors.count - 1) + (1 - core) * 1.4))
                raster.blendStepped(px, py, colors[index], alpha: alpha)
            }
        }
        if heat > 0.3 { raster.glow(cx: cx, cy: cy, radius: r * 2.4, color: 0xE0806A, strength: 0.35 * heat, rings: 3) }

        // The faceted body, turning slowly.
        let rotation = t * 0.22
        let vertices: [(x: Double, y: Double)] = (0..<8).map { k in
            let a = rotation + Double(k) * .pi / 4 + (hash(k, 3, 7) - 0.5) * 0.5
            let rr = r * (0.8 + 0.25 * hash(k, 5, 7))
            return (cx + cos(a) * rr, cy + sin(a) * rr)
        }
        if r < 1.6 {
            raster.fillCircle(cx: cx, cy: cy, radius: max(0.8, r), color: 0x9A6688)
            raster.plot(Int(cx - 0.5), Int(cy + 0.5), Ink.lampHot)
        } else {
            let ridge = (x: cx - r * 0.18, y: cy - r * 0.22)
            let heatDirection = (x: -0.7071, y: 0.7071)   // the leading edge, lower left
            for k in 0..<8 {
                let a = vertices[k], b = vertices[(k + 1) % 8]
                let mx = (a.x + b.x) / 2 - cx, my = (a.y + b.y) / 2 - cy
                let length = max(1e-6, hypot(mx, my))
                let warm = max(0, (mx * heatDirection.x + my * heatDirection.y) / length) * heat
                let skyLight = max(0, -my / length) * 0.4
                let base = Raster.mix(0x3A2440, 0x8E5C84, min(1, 0.3 + skyLight + hash(k, 9, 7) * 0.25))
                polygon([ridge, a, b], color: Raster.mix(base, 0xF0A07C, min(0.75, warm * 0.8)))
            }
            // A molten rim along the leading edge.
            if heat > 0.3 {
                let box = (Int(cx - r - 1), Int(cy - r - 1), Int(cx + r + 1), Int(cy + r + 1))
                for py in box.1...box.3 {
                    for px in box.0...box.2 where Self.contains(vertices, Double(px) + 0.5, Double(py) + 0.5)
                        && !Self.contains(vertices, Double(px) - 0.5, Double(py) + 1.5) {
                        raster.plot(px, py, heat > 0.8 ? Ink.lampHot : 0xF2A88A)
                    }
                }
            }
        }

        // Intermittent fragments peel away below the body.
        guard heat > 0.35 else { return }
        let count = heat > 0.9 ? 8 : heat > 0.6 ? 5 : 2
        for i in 0..<count {
            let life = 5 + hash(i, 1, 51) * 4
            let age = still ? hash(i, 2, 51) * life : (t + hash(i, 3, 51) * life).truncatingRemainder(dividingBy: life)
            let f = age / life
            let px = cx - r * 0.4 + (hash(i, 4, 51) - 0.5) * r - f * r * (1.5 + 2.5 * hash(i, 5, 51))
            let py = cy + r * 0.5 + f * r * (2 + 3.5 * hash(i, 6, 51))
            guard py < Double(horizon) else { continue }
            raster.plot(Int(px), Int(py), f < 0.4 ? Ink.lampHot : f < 0.75 ? 0xE0806A : 0x9A5468)
        }
    }

    static func contains(_ polygon: [(x: Double, y: Double)], _ x: Double, _ y: Double) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > y) != (b.y > y), x < (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: AI Uprising

    /// Original red-eyed machines, searchlights and violet lasers over a waterfront.
    mutating func aiUprising() {
        let horizon = Int(Y(0.68))
        let shore = horizon + n(2, minimum: 1)
        var stops = Self.sky(period)
        switch period {
        case .dusk: stops = [0x141A48, 0x252661, 0x433577, 0x7A4479, 0xC55E66, 0xF98E5E]
        case .night: stops = [0x070B22, 0x0A1030, 0x0E1736, 0x161D46, 0x222960, 0x31336E]
        default: break
        }
        sky(stops, to: horizon + 1)
        switch period {
        case .dawn:
            sun(x: X(0.2), y: Double(horizon) - Y(0.02), radius: max(1.5, 1.8 * u), core: 0xFFE2A8, glow: 0xFFB27A)
            driftingClouds(count: 3, top: 0.06, bottom: 0.4, size: 12, light: 0xF4C0A8, mid: 0xB08AB0, shade: 0x7A6698, seed: 31, speed: 0.5)
        case .day:
            sun(x: X(0.34), y: Y(0.17), radius: max(1.2, 1.5 * u), core: 0xFFF8E2, glow: 0xD4EAFA)
            driftingClouds(count: 3, top: 0.05, bottom: 0.35, size: 12, light: 0xFFFFFF, mid: 0xDCE8F4, shade: 0xA9BED6, seed: 32)
        case .dusk:
            sun(x: X(0.24), y: Double(horizon) - Y(0.1), radius: max(2, 2.3 * u), core: 0xFFB06A, glow: 0xF07C5C)
        case .night:
            stars(until: horizon - n(3), density: 0.012, seed: 17)
            moonDisc(x: X(0.33), y: Y(0.13), radius: max(1.2, 1.4 * u))
        }

        if isEvening { megastructure(horizon: horizon) }
        let tones = cityTones
        let far = skyline(seed: 33, minWidth: 2, maxWidth: 4, minHeight: 0.05, maxHeight: 0.24, gap: 0.1)
        drawBuildings(far, base: horizon, body: tones.far,
                      windows: WindowLights(lit: tones.windows.lit * 0.4, colors: tones.windows.colors.map { Raster.mix($0, tones.far, 0.5) }),
                      seed: 34)
        let mid = skyline(seed: 35, minWidth: 4, maxWidth: 9, minHeight: 0.04, maxHeight: 0.12, gap: 0.45)
        drawBuildings(mid, base: horizon + 1, body: tones.mid, roofline: Raster.mix(tones.mid, 0xFFFFFF, 0.12),
                      windows: tones.windows, seed: 36)

        // Searchlights sweep from the machines; drones patrol above the city.
        if isEvening { searchlights(horizon: horizon) }
        drones(horizon: horizon)

        // Waterfront promenade with trees and lamp posts, then the river.
        raster.fillRect(x: 0, y: horizon + 1, width: w, height: shore - horizon, color: tones.near)
        let treeTone: UInt32 = switch period {
        case .day: 0x2E5A3A
        case .dawn: 0x253A3A
        case .dusk: 0x1E2A30
        case .night: 0x0C1620
        }
        var x = Double(n(2))
        var i = 0
        while x < Double(w) - X(0.1) {
            let size = Double(n(3.2 + 1.6 * hash(i, 1, 37), minimum: 2))
            tree(x: x, base: Double(shore), height: size * 1.6, crown: treeTone, trunk: Raster.mix(treeTone, 0x000000, 0.3),
                 light: period == .day ? 0x3E7A4C : nil)
            if isEvening, hash(i, 2, 37) < 0.5 {
                raster.plot(Int(x + size), shore - n(3), 0xFFD9A0)
            }
            x += size * 2.4 + Double(n(1)) * hash(i, 3, 37) * 4
            i += 1
        }
        water(from: shore, to: h, sky: stops, tint: isNight ? 0x050A18 : 0x1A2440, shimmer: isEvening ? 0x8A7AB8 : 0xCFE2F5)
        if isNight {
            for strip in opticStrips(horizon: horizon) {
                reflection(x: strip, from: shore, to: h, width: 0.6, color: 0xFF697D, strength: 0.6, seed: 39)
            }
        }
        if period == .dusk { reflection(x: X(0.24), from: shore, to: h, width: Double(n(2)), color: 0xFFB06A, strength: 0.8) }
        apartment(base: shore, width: n(8, minimum: 6), height: Int(Y(0.34)), body: Raster.mix(tones.near, 0x000000, 0.2),
                  dim: Raster.mix(tones.mid, 0x000000, 0.1))
    }

    private func opticStrips(horizon: Int) -> [Double] {
        [0.52, 0.56, 0.63, 0.69, 0.84].map { X($0) }
    }

    /// Crisp, blocky machines rising behind the skyline, lit by red optics.
    mutating func megastructure(horizon: Int) {
        let night = isNight
        let body: UInt32 = night ? 0x110F22 : 0x251E3C
        let face: UInt32 = night ? 0x18152C : 0x342850
        let rise = night ? 1.0 : 0.82
        let blocks: [(x: Double, w: Double, h: Double)] = [
            (0.47, 0.20, 0.30), (0.53, 0.10, 0.44), (0.62, 0.12, 0.36), (0.80, 0.11, 0.25), (0.86, 0.05, 0.33)
        ]
        for (k, block) in blocks.enumerated() {
            let bw = Int(X(block.w)), bh = Int(Y(block.h * rise))
            let bx = Int(X(block.x))
            let top = horizon - bh
            raster.fillRect(x: bx, y: top, width: bw, height: bh + 1, color: body)
            // A lit face on one side and a setback on top.
            raster.fillRect(x: bx, y: top, width: max(1, bw / 4), height: bh, color: face)
            raster.fillRect(x: bx + bw / 4, y: top - n(2), width: bw / 2, height: n(2), color: body)
            if k == 1 {
                // The central tower's visor.
                let eyeY = top + n(3)
                let eyeX = bx + bw / 5
                let eyeWidth = max(2, bw * 3 / 5)
                let pulse = still ? 1 : 0.75 + 0.25 * wave(6)
                if night {
                    raster.glow(cx: Double(eyeX + eyeWidth / 2), cy: Double(eyeY), radius: Double(eyeWidth), color: 0x8A2A40, strength: 0.8 * pulse)
                }
                raster.fillRect(x: eyeX, y: eyeY, width: eyeWidth, height: 1, color: night ? 0xFF697D : 0xC24A60)
            }
        }
        // Vertical optic strips, pulsing on their own loops.
        for (k, x) in opticStrips(horizon: horizon).enumerated() {
            let length = Int(Y(0.09 + 0.05 * hash(k, 1, 41)))
            let top = horizon - Int(Y(0.12 + 0.12 * hash(k, 2, 41)))
            let pulse = still ? 1 : 0.6 + 0.4 * wave(9 + Double(k) * 2.3, offset: hash(k, 3, 41))
            if night { raster.glow(cx: x, cy: Double(top + length / 2), radius: Double(length) * 0.7, color: 0x5A1E38, strength: 0.7 * pulse) }
            for y in top..<(top + length) { raster.plot(Int(x), y, Raster.mix(0x8A3048, 0xFF697D, pulse)) }
        }
    }

    mutating func searchlights(horizon: Int) {
        let sources = [(x: X(0.56), y: Double(horizon) - Y(0.44)), (x: X(0.88), y: Double(horizon) - Y(0.33))]
        for (k, source) in sources.enumerated() {
            let angle = -.pi / 2 + (still ? (k == 0 ? -0.5 : 0.4) : sin(t / (13 + Double(k) * 4) + Double(k) * 2) * 0.75)
            let length = Y(0.75)
            let spread = 0.09
            let steps = Int(length)
            for i in 1..<max(2, steps) {
                let s = Double(i) / Double(steps)
                let half = Double(i) * spread
                let cx = source.x + cos(angle) * Double(i), cy = source.y + sin(angle) * Double(i)
                for j in Int(-half)...Int(half) {
                    let px = cx + cos(angle + .pi / 2) * Double(j), py = cy + sin(angle + .pi / 2) * Double(j)
                    guard py < Double(horizon) else { continue }
                    raster.blendStepped(Int(px), Int(py), 0xD8B5FF, alpha: 0.3 * (1 - s))
                }
            }
        }
    }

    mutating func drones(horizon: Int) {
        let count = [ScenePeriod.dawn: 1, .day: 2, .dusk: 3, .night: 4][period] ?? 1
        let bodyColor: UInt32 = period == .day ? 0x3A4256 : 0x161A28
        for i in 0..<count {
            let span = Double(w) + X(0.2)
            let speed = (0.6 + hash(i, 1, 43)) * u * (hash(i, 4, 43) < 0.5 ? 1 : -1)
            var x = (hash(i, 2, 43) * span + t * speed).truncatingRemainder(dividingBy: span)
            if x < 0 { x += span }
            x -= X(0.1)
            let y = Y(0.12 + 0.3 * hash(i, 3, 43)) + (still ? 0 : sin(t * 1.3 + Double(i)) * 0.6)
            let size = period == .dawn ? 1 : n(1.6, minimum: 1)
            raster.fillRect(x: Int(x) - size, y: Int(y), width: size * 2 + 1, height: max(1, size / 2 + 1), color: bodyColor)
            raster.plot(Int(x), Int(y) + max(1, size / 2 + 1) - 1, 0xFF697D)
            if !still, isNight, i % 2 == 0 {
                // A brief laser burst, separated by several seconds.
                let cycle = 11 + Double(i) * 3
                let phase = (t + Double(i) * 4).truncatingRemainder(dividingBy: cycle)
                if phase < 0.35 {
                    let target = (x: x - X(0.05) + X(0.1) * hash(Int(t / cycle), i, 45), y: Double(horizon) - Y(0.03))
                    raster.line(from: (x, y + 1), to: target, color: 0xD8B5FF)
                    raster.glow(cx: target.x, cy: target.y, radius: Double(n(3)), color: 0xD8B5FF, strength: 0.9)
                }
            }
        }
    }

    // MARK: Fallout Outlook

    /// An amber horizon, a monumental distant cloud and drifting flecks. Stillness carries the unease.
    mutating func falloutOutlook() {
        let horizon = Int(Y(0.80))
        let stops: [UInt32] = switch period {
        case .dawn: [0x241F3A, 0x3A3156, 0x5E4470, 0x93607A, 0xC98572, 0xEFB27E]
        case .day: [0x5576A6, 0x6889B5, 0x82A0C2, 0xA2B6CA, 0xC3C8C6, 0xDCCDB0]
        case .dusk: [0x221C38, 0x3A2A4C, 0x60395A, 0x9A5560, 0xD59A68, 0xF8C98A]
        case .night: [0x15131D, 0x1C1925, 0x24202E, 0x2C2735, 0x35303D, 0x403946]
        }
        sky(stops, to: horizon + 1)
        switch period {
        case .dawn: sun(x: X(0.2), y: Double(horizon), radius: max(1.5, 1.8 * u), core: 0xFFE2A8, glow: 0xFFB27A)
        case .day: sun(x: X(0.3), y: Y(0.15), radius: max(1.2, 1.3 * u), core: 0xFFF6DC, glow: 0xE6E2D0)
        case .dusk: sun(x: X(0.14), y: Double(horizon) - Y(0.03), radius: max(2, 2.4 * u), core: 0xFFC27A, glow: 0xE88A5C)
        case .night: break
        }
        if period != .night {
            let tint: (UInt32, UInt32, UInt32) = period == .day ? (0xF4EEE4, 0xC9CBD0, 0x9AA2B4) : (0xF2B48E, 0x9A6478, 0x5E4366)
            driftingClouds(count: 3, top: 0.08, bottom: 0.35, size: 13, light: tint.0, mid: tint.1, shade: tint.2, seed: 51, speed: 0.4)
        }

        let tones: (light: UInt32, mid: UInt32, shade: UInt32, stem: UInt32) = switch period {
        case .dawn: (0xF2C2A0, 0xB48298, 0x76587E, 0x9A7488)
        case .day: (0xFBF3E4, 0xD8CCC0, 0xA48E9A, 0xC2B2AE)
        case .dusk: (0xF8D599, 0xD59A68, 0x76506B, 0xB07466)
        case .night: (0x5E5466, 0x463D50, 0x2E2838, 0x3C3446)
        }
        let rise = still ? 0 : (0.5 + 0.5 * wave(40)) * Y(0.012)
        switch period {
        case .dawn:
            mushroomCloud(cx: X(0.64), ground: Double(horizon), height: Y(0.42), tones: tones, rise: rise)
        default:
            mushroomCloud(cx: X(0.33), ground: Double(horizon), height: Y(0.28), tones: tones, rise: rise * 0.6)
            mushroomCloud(cx: X(0.67), ground: Double(horizon), height: Y(0.6), tones: tones, rise: rise)
        }

        let tones2 = cityTones
        let far = skyline(seed: 53, minWidth: 2, maxWidth: 4, minHeight: 0.05, maxHeight: 0.2, gap: 0.08)
        let lit = period == .night ? 0.06 : tones2.windows.lit * 0.5
        drawBuildings(far, base: horizon, body: tones2.far,
                      windows: WindowLights(lit: lit, colors: tones2.windows.colors.map { Raster.mix($0, tones2.far, 0.4) }), seed: 54)
        let near = skyline(seed: 55, minWidth: 3, maxWidth: 6, minHeight: 0.03, maxHeight: 0.12, gap: 0.3)
        drawBuildings(near, base: horizon + n(1),
                      body: tones2.mid, windows: WindowLights(lit: period == .night ? 0.1 : tones2.windows.lit, colors: tones2.windows.colors), seed: 56)
        raster.fillRect(x: 0, y: horizon + n(1), width: w, height: h, color: tones2.near)
        apartment(base: h, width: n(9, minimum: 6), height: Int(Y(0.28)), body: Raster.mix(tones2.near, 0x000000, 0.25),
                  dim: Raster.mix(tones2.mid, 0x000000, 0.1))

        // Drifting flecks.
        if period != .dawn {
            let count = Int(Double(w * h) / (period == .night ? 90 : 220))
            let color: UInt32 = period == .night ? 0xB8B0B8 : period == .dusk ? 0xF8D599 : 0xE8E0D4
            for i in 0..<count {
                let speed = (0.6 + hash(i, 1, 57)) * u
                let x = Int((hash(i, 2, 57) * Double(w) + sin(t * 0.4 + Double(i)) * 1.5 + t * 0.3 * u).truncatingRemainder(dividingBy: Double(w)))
                let y = Int((hash(i, 3, 57) * Double(h) + t * speed).truncatingRemainder(dividingBy: Double(h)))
                raster.blend(x: x, y: y, color: color, alpha: 0.45 + 0.4 * hash(i, 4, 57))
            }
        }
    }

    /// A remote cloud: a broad cap, a collar, a slender stem and a low base surge.
    mutating func mushroomCloud(cx: Double, ground: Double, height ch: Double, tones: (light: UInt32, mid: UInt32, shade: UInt32, stem: UInt32), rise: Double) {
        let capR = ch * 0.24
        let capY = ground - ch + capR * 0.95 - rise
        // Stem: slender, widening toward the ground and just under the cap.
        let stemTop = capY + capR * 0.4
        for y in Int(stemTop)..<Int(ground) {
            let f = max(0, (Double(y) - stemTop) / max(1, ground - stemTop))
            let half = capR * (0.26 + 0.5 * pow(f, 2.2)) + (f < 0.12 ? capR * 0.18 * (1 - f / 0.12) : 0)
            for x in Int(cx - half)...Int(cx + half) {
                let edge = abs(Double(x) + 0.5 - cx) / max(0.5, half)
                let color = edge > 0.6 ? tones.shade : (hash(x, y / 2, 59) > 0.7 ? tones.mid : tones.stem)
                raster.plot(x, y, color)
            }
        }
        // Collar ring part way up the stem.
        let ringY = stemTop + (ground - stemTop) * 0.42
        let ringR = capR * (0.9 + (still ? 0 : 0.08 * (0.5 + 0.5 * wave(30))))
        raster.fillEllipse(cx: cx, cy: ringY, rx: ringR, ry: max(1, capR * 0.13), color: tones.mid, alpha: 0.55)
        // Base surge along the ground.
        cloud(x: cx, y: ground - capR * 0.25, width: capR * 3.4, height: capR * 0.75, light: tones.mid, mid: tones.mid, shade: tones.shade, seed: 61)
        // The cap: overlapping puffs, lit from the upper left.
        let puffs: [(x: Double, y: Double, r: Double)] = [
            (cx, capY, capR), (cx - capR * 0.75, capY + capR * 0.22, capR * 0.68), (cx + capR * 0.75, capY + capR * 0.22, capR * 0.68),
            (cx - capR * 0.3, capY - capR * 0.35, capR * 0.7), (cx + capR * 0.35, capY - capR * 0.3, capR * 0.66),
            (cx - capR * 1.2, capY + capR * 0.45, capR * 0.42), (cx + capR * 1.2, capY + capR * 0.45, capR * 0.42)
        ]
        let underside = capY + capR * 0.62
        let minX = Int(cx - capR * 1.8), maxX = Int(cx + capR * 1.8), minY = Int(capY - capR * 1.2), maxY = Int(underside + 1)
        for py in minY...maxY {
            for px in minX...maxX {
                let x = Double(px) + 0.5, y = Double(py) + 0.5
                guard y < underside else { continue }
                var best: (x: Double, y: Double, r: Double)?
                var depth = 0.0
                for p in puffs {
                    let d = hypot(x - p.x, y - p.y) / p.r
                    if d <= 1, (best == nil || 1 - d > depth) { best = p; depth = 1 - d }
                }
                guard let p = best else { continue }
                let nx = (x - p.x) / p.r, ny = (y - p.y) / p.r
                let light = -0.6 * nx - 0.8 * ny
                let bottomShade = (y - (capY + capR * 0.2)) / (capR * 0.42)
                var color = light > 0.45 ? tones.light : light > -0.1 ? tones.mid : tones.shade
                if bottomShade > 0.5 { color = tones.shade }
                // Rolling bands in the cap.
                if color == tones.mid, sin(y * 1.3 / max(1, u) + x * 0.15) > 0.85 { color = tones.shade }
                raster.plot(px, py, color)
            }
        }
    }
}
