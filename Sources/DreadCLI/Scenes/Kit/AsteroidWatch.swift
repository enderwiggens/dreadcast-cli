import Foundation
import DreadTerminal

/// Asteroid Watch, drawn for the terminal: a faceted rock and a banded coral trail
/// over a city whose windows are still on. Dawn shows a speck; night shows the whole
/// situation. Deep sky #17142F, atmosphere #BD6876, signal #FFCC9F, stone #684268.
enum AsteroidWatch {
    struct Tones {
        let sky: [UInt32]
        let far: UInt32
        let near: UInt32
        let street: UInt32
        let lit: Double
        let windows: [UInt32]
    }

    static func tones(_ period: ScenePeriod) -> Tones {
        switch period {
        case .dawn:
            Tones(sky: [0x2A2552, 0x41336C, 0x634281, 0x8E5288, 0xBE6A86, 0xE89286], far: 0x5C4C80, near: 0x2D2849,
                  street: 0x1C1830, lit: 0.22, windows: [Ink.lamp, 0xF2B07E, 0xFFE0B0])
        case .day:
            Tones(sky: [0x3466B4, 0x4579C2, 0x5A8DCE, 0x74A3DA, 0x93BAE4, 0xB4D0EC], far: 0x8AA4C4, near: 0x4D6486,
                  street: 0x35415A, lit: 0.1, windows: [0xC4D6E8, 0xA8C0D8])
        case .dusk:
            Tones(sky: [0x1D1838, 0x2D204C, 0x47295C, 0x6E3564, 0x9C4A6A, 0xBD6876, 0xEC957C], far: 0x4C3862, near: 0x281F3E,
                  street: 0x181326, lit: 0.42, windows: [Ink.lamp, 0xF2B07E, 0xFFE0B0, 0xE89A6A])
        case .night:
            Tones(sky: [0x08081A, 0x0C0C22, 0x11102A, 0x171533, 0x1F1A3D, 0x281F48], far: 0x1C1A38, near: 0x0F0F24,
                  street: 0x09091A, lit: 0.55, windows: [Ink.lamp, 0xF2B07E, 0xFFE0B0, 0xE8A06A])
        }
    }

    static func draw(_ s: inout Stage) {
        let tones = tones(s.period)
        let ground = s.layout == .strip ? 2 : (s.layout == .window ? 5 : 3)
        let horizon = s.h - ground
        s.bands(tones.sky, bottom: horizon + 1)

        // Sun, moon and clouds stay left of the event.
        switch s.period {
        case .dawn:
            s.sun(x: s.w / 5, y: horizon - 1, radius: 2, core: 0xFFE2A8, glow: 0xF8A27C)
            s.driftingClouds(max(1, s.w / 50), top: 2, bottom: horizon / 2, light: 0xF4BCA2, mid: 0xB487A6, shade: 0x7A6494, seed: 11)
        case .day:
            s.sun(x: s.w / 4, y: max(3, horizon / 4), radius: 2, core: 0xFFF8E2, glow: 0xD6EAF8)
            s.driftingClouds(max(1, s.w / 40), top: 1, bottom: horizon / 2, light: 0xFFFFFF, mid: 0xDDE8F4, shade: 0xA9BED6, seed: 12)
        case .dusk:
            s.sun(x: s.w / 6, y: horizon - 1, radius: 3, core: 0xFFB06A, glow: 0xF07C5C)
            s.driftingClouds(max(1, s.w / 50), top: 2, bottom: horizon / 2, light: 0xF6A48A, mid: 0x9C5A78, shade: 0x5E3A62, seed: 13)
        case .night:
            s.stars(above: horizon - 6)
            s.moonDisc(x: s.w / 4, y: max(3, horizon / 5), radius: s.layout == .window ? 2 : 1)
        }

        let rock = hero(s, horizon: horizon)
        skyline(&s, horizon: horizon, tones: tones, rockX: rock.x)
        incoming(&s, x: rock.x, y: rock.y, radius: rock.radius, horizon: horizon)
        // The street, with lamps after dark.
        s.raster.fillRect(x: 0, y: horizon + 1, width: s.w, height: s.h - horizon - 1, color: tones.street)
        if s.isEvening {
            for x in stride(from: 5, to: s.w, by: 11) { s.raster.plot(x, horizon + 1, 0xFFD9A0) }
        }
    }

    /// Where the rock is, and how big: it grows from a speck at dawn to a body at night.
    static func hero(_ s: Stage, horizon: Int) -> (x: Int, y: Int, radius: Double) {
        let sizes: [ScenePeriod: [SceneLayout: Double]] = [
            .dawn: [.window: 1.5, .panorama: 1.2, .strip: 1],
            .day: [.window: 4, .panorama: 3.2, .strip: 2.2],
            .dusk: [.window: 6, .panorama: 4.6, .strip: 3],
            .night: [.window: 8.5, .panorama: 6.2, .strip: 3.6],
        ]
        let radius = sizes[s.period]?[s.layout] ?? 3
        let height: [ScenePeriod: Double] = [.dawn: 0.32, .day: 0.36, .dusk: 0.42, .night: 0.46]
        let y = Int(Double(horizon) * (height[s.period] ?? 0.4))
        return (Int(Double(s.w) * 0.66), max(Int(radius) + 1, y), radius)
    }

    // MARK: The city

    static func skyline(_ s: inout Stage, horizon: Int, tones: Tones, rockX: Int) {
        let sky = horizon
        let farMax = s.layout == .strip ? 7 : min(18, max(7, sky * 2 / 5))
        let nearMax = s.layout == .strip ? 5 : min(11, max(5, sky / 4))
        s.buildings(base: horizon, seed: 21, widths: 3...7, heights: max(3, farMax / 3)...farMax,
                               body: tones.far, lit: tones.lit * 0.4, windows: tones.windows.map { Raster.mix($0, tones.far, 0.45) })
        let near = s.buildings(base: horizon, seed: 22, widths: 5...11, heights: 2...nearMax,
                             body: tones.near, lit: tones.lit, windows: tones.windows)
        // A radio mast on the tallest near building, its light blinking.
        if let tallest = near.max(by: { $0.height < $1.height }), s.layout != .strip {
            let mx = tallest.x + tallest.width / 2
            for y in (horizon - tallest.height - 4)..<(horizon - tallest.height) { s.raster.plot(mx, y, tones.near) }
            if s.isEvening || s.period == .dawn {
                s.raster.plot(mx, horizon - tallest.height - 5, s.tick(1.1, frames: 2) == 0 || s.still ? 0xFF4A4A : 0x5A1A24)
            }
        }
        // At night the rock warms the horizon beneath it.
        if s.isNight {
            s.raster.glow(cx: Double(rockX - 8), cy: Double(horizon), radius: 18, color: 0xBD6876, strength: 0.1, rings: 2)
        }
    }

    // MARK: The event

    static func incoming(_ s: inout Stage, x cx: Int, y cy: Int, radius r: Double, horizon: Int) {
        // The trail rises up and to the right at a clean two-across, one-up step.
        let dir = (x: 2 / 5.0.squareRoot(), y: -1 / 5.0.squareRoot())
        let perp = (x: 1 / 5.0.squareRoot(), y: 2 / 5.0.squareRoot())
        let length = r * 9 + 10
        let bands: [UInt32] = [Ink.lampHot, Ink.lamp, 0xF2A088, 0xBD6876, 0x7A4A6E]
        // Bright streaks travel outward along the trail, four steps a second.
        let streak = Double(s.tick(0.25, frames: 10_000)) * 3
        let cxd = Double(cx) + 0.5, cyd = Double(cy) + 0.5
        let reach = Int(length) + Int(r) + 4
        for py in max(0, cy - reach)...min(horizon, cy + Int(r) + 2) {
            for px in max(0, cx - Int(r) - 2)...min(s.w - 1, cx + reach * 2) {
                let vx = Double(px) + 0.5 - cxd, vy = Double(py) + 0.5 - cyd
                let along = vx * dir.x + vy * dir.y
                guard along > 0, along < length else { continue }
                let across = abs(vx * perp.x + vy * perp.y)
                let fraction = along / length
                let half = r * (1.05 - 0.6 * fraction)
                guard across < half else { continue }
                var band = Int(across / half * 4)
                band += fraction > 0.75 ? 2 : fraction > 0.45 ? 1 : 0
                if fraction > 0.88, (px + py) % 2 == 0 { continue }
                if band < 2, Int(along - streak) % 9 == 0 { band = 0 }
                s.raster.plot(px, py, bands[min(bands.count - 1, band)])
            }
        }
        // Fine orbital lines beside the trail.
        if r >= 4, s.layout != .strip {
            for offset in [-(r + 3), r + 4] {
                var step = Int(r) + 2
                while Double(step) < length * 1.15 {
                    let px = Int(cxd + perp.x * offset + dir.x * Double(step)), py = Int(cyd + perp.y * offset + dir.y * Double(step))
                    if step % 7 != 0, py < horizon - 2 { s.raster.plot(px, py, 0x8A5A86) }
                    step += 1
                }
            }
        }
        if r >= 5 { s.raster.glow(cx: cxd, cy: cyd, radius: r * 1.9, color: 0xE0806A, strength: s.isNight ? 0.2 : 0.14, rings: 2) }
        rock(&s, cx: cxd, cy: cyd, r: r)
        // Fragments flake off the sides of the body and fall behind it along the trail,
        // cooling from hot to coral to violet as they go.
        let chips = r >= 8 ? 11 : r >= 5 ? 6 : 0
        for i in 0..<chips {
            let life = 20 + Int(s.hash(i, 4, 31) * 12)
            let age = s.tick(0.2, frames: life, offset: s.hash(i, 1, 31) * 8)
            let f = Double(age) / Double(life)
            let along = r * 0.5 + f * (r * 4 + 12) * (0.7 + 0.5 * s.hash(i, 3, 31))
            let side: Double = i % 2 == 0 ? 1 : -1
            let half = r * (1.05 - 0.6 * min(1, along / length))
            let across = side * half * (0.95 + 0.35 * s.hash(i, 2, 31) + 0.4 * f)
            let px = Int(cxd + dir.x * along + perp.x * across)
            let py = Int(cyd + dir.y * along + perp.y * across)
            guard py >= 0, py < horizon - 1 else { continue }
            let color: UInt32 = f < 0.3 ? Ink.lampHot : f < 0.65 ? 0xE0806A : 0x8A5A86
            // A short dash along the trail: bright head, dimmer pixel toward the rock.
            if r >= 8, f < 0.65 {
                s.raster.plot(Int(Double(px) - dir.x * 1.6), Int(Double(py) - dir.y * 1.6), f < 0.3 ? 0xE0806A : 0x8A5A86)
            }
            s.raster.plot(px, py, color)
        }
    }

    /// A faceted body in four flat tones, turning in slow steps, hot along its leading edge.
    static func rock(_ s: inout Stage, cx: Double, cy: Double, r: Double) {
        if r < 2 {
            s.raster.plot(Int(cx), Int(cy), Ink.lampHot)
            s.raster.plot(Int(cx) + 1, Int(cy), 0xBD6876)
            s.raster.plot(Int(cx), Int(cy) - 1, 0x946090)
            return
        }
        let turn = Double(s.tick(2.5, frames: 12)) * (.pi / 24)
        let vertices: [(x: Double, y: Double)] = (0..<8).map { k in
            let a = turn + Double(k) * .pi / 4 + (s.hash(k, 3, 7) - 0.5) * 0.5
            let rr = r * (0.82 + 0.22 * s.hash(k, 5, 7))
            return (cx + cos(a) * rr, cy + sin(a) * rr)
        }
        let ridge = (x: cx - r * 0.2, y: cy - r * 0.25)
        let tones: [UInt32] = [0x3A2440, 0x5A3A5E, 0x7A4E78, 0x9A6890]
        for k in 0..<8 {
            let a = vertices[k], b = vertices[(k + 1) % 8]
            let mx = (a.x + b.x) / 2 - cx, my = (a.y + b.y) / 2 - cy
            let length = max(1e-6, hypot(mx, my))
            let light = (-mx * 0.5 - my * 0.85) / length          // ambient light from the upper left
            let tone = light > 0.45 ? 3 : light > 0 ? 2 : light > -0.5 ? 1 : 0
            s.raster.fillPolygons([[ridge, a, b]], color: tones[tone])
        }
        // A molten rim on the lower-left, leading edge.
        let box = (Int(cx - r - 1), Int(cy - r - 1), Int(cx + r + 1), Int(cy + r + 1))
        for py in box.1...box.3 {
            for px in box.0...box.2 {
                let x = Double(px) + 0.5, y = Double(py) + 0.5
                guard Stage.contains(vertices, x, y), !Stage.contains(vertices, x - 1, y + 1) else { continue }
                let facing = (x - cx) * -0.7 + (y - cy) * 0.7
                if facing > 0 { s.raster.plot(px, py, facing > r * 0.4 ? Ink.lampHot : 0xF2A088) }
            }
        }
    }
}
