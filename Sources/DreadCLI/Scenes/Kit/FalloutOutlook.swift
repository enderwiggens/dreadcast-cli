import Foundation
import DreadTerminal

/// Fallout Outlook, drawn for the terminal: an amber horizon, a monumental distant
/// cloud behind the skyline and drifting flecks. Stillness carries the unease.
/// Deep sky #262137, atmosphere #D59A68, signal #F8D599, cloud #76506B.
enum FalloutOutlook {
    struct Tones {
        let sky: [UInt32]
        let cloud: (light: UInt32, mid: UInt32, shade: UInt32, stem: UInt32)
        let far: UInt32
        let near: UInt32
        let street: UInt32
        let lit: Double
        let windows: [UInt32]
        let flecks: UInt32?
    }

    static func tones(_ period: ScenePeriod) -> Tones {
        switch period {
        case .dawn:
            Tones(sky: [0x241F3A, 0x372F54, 0x55406C, 0x845A7A, 0xBC7E74, 0xEAAE7E], cloud: (0xF2C2A0, 0xB48298, 0x76587E, 0x9A7488),
                  far: 0x524468, near: 0x2C2440, street: 0x1C1830, lit: 0.18, windows: [Ink.lamp, 0xF2B07E], flecks: nil)
        case .day:
            Tones(sky: [0x5274A4, 0x6486B2, 0x7C9CC0, 0x9AB2C8, 0xBAC2C4, 0xD8CCB0], cloud: (0xFBF3E4, 0xD8CCC0, 0xA48E9A, 0xC2B2AE),
                  far: 0x8A96AE, near: 0x56607A, street: 0x3E4454, lit: 0.08, windows: [0xC4D0DC], flecks: 0xE8E0D4)
        case .dusk:
            Tones(sky: [0x221C38, 0x382A4C, 0x5C3858, 0x92525E, 0xCC9066, 0xF6C688], cloud: (0xF8D599, 0xD59A68, 0x76506B, 0xB07466),
                  far: 0x4A3654, near: 0x261C34, street: 0x161222, lit: 0.3, windows: [Ink.lamp, 0xF2B07E, 0xF8D599], flecks: 0xF8D599)
        case .night:
            Tones(sky: [0x14121C, 0x1A1724, 0x211D2C, 0x292434, 0x322C3C, 0x3C3444], cloud: (0x5E5466, 0x463D50, 0x2E2838, 0x3C3446),
                  far: 0x221E2E, near: 0x14121C, street: 0x0E0C14, lit: 0.06, windows: [Ink.lamp], flecks: 0xB8B0B8)
        }
    }

    static func draw(_ s: inout Stage) {
        let tones = tones(s.period)
        let strip = s.layout == .strip
        let horizon = s.h - (strip ? 2 : (s.layout == .window ? 5 : 3))
        s.bands(tones.sky, bottom: horizon + 1)
        switch s.period {
        case .dawn: s.sun(x: s.w / 5, y: horizon, radius: 2, core: 0xFFE2A8, glow: 0xF8A27C)
        case .day: s.sun(x: s.w / 4, y: max(3, horizon / 5), radius: 2, core: 0xFFF6DC, glow: 0xE6E2D0)
        case .dusk: s.sun(x: s.w / 7, y: horizon - 2, radius: 3, core: 0xFFC27A, glow: 0xE88A5C)
        case .night: break
        }
        if s.period != .night {
            let day = s.period == .day
            s.driftingClouds(max(1, s.w / 50), top: 1, bottom: horizon / 3, light: day ? 0xF4EEE4 : 0xF2B48E,
                             mid: day ? 0xC9CBD0 : 0x9A6478, shade: day ? 0x9AA2B4 : 0x5E4366, seed: 91)
        }

        // The clouds stand behind the city; only their tops clear the skyline.
        let sky = Double(horizon)
        let big = strip ? 0.85 : 0.8, small = strip ? 0.45 : 0.42
        let rise = s.tick(4, frames: 2)
        switch s.period {
        case .dawn:
            mushroom(&s, x: s.w * 16 / 25, ground: horizon, height: Int(sky * small) + 3, tones: tones.cloud, rise: rise)
        default:
            mushroom(&s, x: s.w / 3, ground: horizon, height: Int(sky * small), tones: tones.cloud, rise: 0)
            mushroom(&s, x: s.w * 2 / 3, ground: horizon, height: Int(sky * big), tones: tones.cloud, rise: rise)
        }

        let farMax = strip ? 7 : min(20, max(8, horizon * 2 / 5))
        s.buildings(base: horizon, seed: 92, widths: 2...5, heights: max(3, farMax / 3)...farMax, body: tones.far,
                    lit: tones.lit * 0.5, windows: tones.windows.map { Raster.mix($0, tones.far, 0.4) })
        let nearMax = strip ? 4 : min(11, max(4, horizon / 4))
        s.buildings(base: horizon, seed: 93, widths: 4...9, heights: 2...nearMax, body: tones.near, lit: tones.lit, windows: tones.windows)
        s.raster.fillRect(x: 0, y: horizon + 1, width: s.w, height: s.h - horizon - 1, color: tones.street)

        // Flecks drifting down, stepping a few times a second.
        if let fleck = tones.flecks {
            let count = s.w * s.h / (s.isNight ? 80 : 200)
            let step = s.tick(0.25, frames: 100_000)
            for i in 0..<count {
                let x = (Int(s.hash(i, 1, 94) * Double(s.w)) + step / 6 + (step / 3 + i) % 2) % s.w
                let y = (Int(s.hash(i, 2, 94) * Double(s.h)) + step * (1 + i % 2) / 2) % s.h
                s.raster.blend(x: x, y: y, color: fleck, alpha: 0.5 + 0.4 * s.hash(i, 3, 94))
            }
        }
    }

    /// A remote cloud in flat tones: a broad cap lit from the upper left, a collar ring,
    /// a slender stem and a low surge at its base.
    static func mushroom(_ s: inout Stage, x center: Int, ground: Int, height: Int, tones: (light: UInt32, mid: UInt32, shade: UInt32, stem: UInt32), rise: Int) {
        guard height >= 6 else { return }
        let cap = Double(height) * 0.26
        let capY = Double(ground - height) + cap * 0.95 - Double(rise)
        let cx = Double(center) + 0.5
        // Stem, widening toward the ground and just under the cap.
        let stemTop = Int(capY + cap * 0.4)
        for y in stride(from: max(0, stemTop), to: ground, by: 1) {
            let f = Double(y - stemTop) / Double(max(1, ground - stemTop))
            let half = cap * (0.28 + 0.45 * f * f) + (f < 0.1 ? cap * 0.15 : 0)
            for x in Int(cx - half)...Int(cx + half) {
                let edge = abs(Double(x) + 0.5 - cx) / max(0.5, half)
                s.raster.plot(x, y, edge > 0.6 ? tones.shade : (x + y / 2) % 4 == 0 ? tones.mid : tones.stem)
            }
        }
        // The collar ring, part way up.
        let ringY = Double(stemTop) + Double(ground - stemTop) * 0.42
        s.raster.fillEllipse(cx: cx, cy: ringY, rx: cap * 0.95, ry: max(1, cap * 0.16), color: tones.mid)
        s.raster.fillEllipse(cx: cx, cy: ringY - 0.5, rx: cap * 0.7, ry: max(0.6, cap * 0.08), color: tones.light)
        // The cap: overlapping puffs, shaded in three flat tones.
        let puffs: [(x: Double, y: Double, r: Double)] = [
            (cx, capY, cap), (cx - cap * 0.75, capY + cap * 0.25, cap * 0.68), (cx + cap * 0.75, capY + cap * 0.25, cap * 0.68),
            (cx - cap * 0.3, capY - cap * 0.38, cap * 0.7), (cx + cap * 0.35, capY - cap * 0.32, cap * 0.66),
            (cx - cap * 1.25, capY + cap * 0.5, cap * 0.42), (cx + cap * 1.25, capY + cap * 0.5, cap * 0.42),
        ]
        let underside = capY + cap * 0.62
        for py in Int(capY - cap * 1.2)...Int(underside) {
            for px in Int(cx - cap * 1.8)...Int(cx + cap * 1.8) {
                let x = Double(px) + 0.5, y = Double(py) + 0.5
                guard y < underside else { continue }
                var best: (x: Double, y: Double, r: Double)?
                var depth = 0.0
                for p in puffs {
                    let d = hypot(x - p.x, y - p.y) / p.r
                    if d <= 1, best == nil || 1 - d > depth { best = p; depth = 1 - d }
                }
                guard let p = best else { continue }
                let light = (-0.6 * (x - p.x) - 0.8 * (y - p.y)) / p.r
                var color = light > 0.4 ? tones.light : light > -0.15 ? tones.mid : tones.shade
                if y > capY + cap * 0.35 { color = tones.shade }
                s.raster.plot(px, py, color)
            }
        }
    }
}
