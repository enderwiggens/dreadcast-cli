import Foundation
import DreadTerminal

/// AI Uprising, drawn for the terminal: a waterfront city with a machine rising
/// behind it, one red visor, violet searchlights and patrols with red eyes.
/// Deep sky #0E1736, atmosphere #4C4989, signal #D8B5FF, optics #FF697D.
enum AIUprising {
    struct Tones {
        let sky: [UInt32]
        let machine: UInt32
        let face: UInt32
        let far: UInt32
        let near: UInt32
        let promenade: UInt32
        let tree: [Character: UInt32]
        let water: [UInt32]
        let highlight: UInt32
        let lit: Double
        let windows: [UInt32]
        let drone: UInt32
    }

    static func tones(_ period: ScenePeriod) -> Tones {
        switch period {
        case .dawn:
            Tones(sky: [0x262A5C, 0x3B3C7B, 0x5C4E94, 0x8C629C, 0xC67E92, 0xF0A48A], machine: 0x3A3458, face: 0x4C4470,
                  far: 0x5E5484, near: 0x34305A, promenade: 0x1E1C36, tree: ["c": 0x233A3A, "C": 0x2E4A44, "k": 0x141E22],
                  water: [0x34386A, 0x2A2E5A, 0x20244A], highlight: 0x8A84B8, lit: 0.2, windows: [Ink.lamp, 0xF2B07E], drone: 0x2A2A44)
        case .day:
            Tones(sky: [0x3066B8, 0x3E7AC6, 0x5290D2, 0x6CA6DE, 0x8CBEE8, 0xB0D6F0], machine: 0x7C8EAC, face: 0x8EA0BC,
                  far: 0x8CA6C6, near: 0x5A7496, promenade: 0x3A4A62, tree: ["c": 0x2E5A3A, "C": 0x3E7A4C, "k": 0x1E3A26],
                  water: [0x3A6EA8, 0x2E5C94, 0x244C80], highlight: 0xC8E0F4, lit: 0.08, windows: [0xC6D9EA], drone: 0x3A4256)
        case .dusk:
            Tones(sky: [0x141A48, 0x232660, 0x3E3476, 0x6E4278, 0xB05C6C, 0xF08A60], machine: 0x221C3A, face: 0x342852,
                  far: 0x4E3A64, near: 0x2A2244, promenade: 0x161228, tree: ["c": 0x1A2228, "C": 0x242E34, "k": 0x0E1216],
                  water: [0x2A2A5A, 0x22224C, 0x1A1A3E], highlight: 0x8A6A9A, lit: 0.4, windows: [Ink.lamp, 0xF2B07E, 0xFFE0B0], drone: 0x161424)
        case .night:
            Tones(sky: [0x070B22, 0x0A1030, 0x0E1736, 0x141C44, 0x1C2454, 0x262E62], machine: 0x100E20, face: 0x18152C,
                  far: 0x171C38, near: 0x0F1328, promenade: 0x0A0C1A, tree: ["c": 0x0A1416, "C": 0x10201E, "k": 0x060A0C],
                  water: [0x0A1028, 0x080C20, 0x060818], highlight: 0x3A3E70, lit: 0.55, windows: [Ink.lamp, 0xF2B07E, 0xFFE0B0, 0x9FB8D8], drone: 0x161A28)
        }
    }

    static func draw(_ s: inout Stage) {
        let tones = tones(s.period)
        let strip = s.layout == .strip
        let water = strip ? 3 : (s.layout == .window ? 9 : 5)
        let horizon = s.h - water - 2
        s.bands(tones.sky, bottom: horizon + 1)

        switch s.period {
        case .dawn:
            s.sun(x: s.w / 5, y: horizon - 2, radius: 2, core: 0xFFE2A8, glow: 0xF8A27C)
            s.driftingClouds(max(1, s.w / 50), top: 1, bottom: horizon / 2, light: 0xF4C0A8, mid: 0xB08AB0, shade: 0x7A6698, seed: 101)
        case .day:
            s.sun(x: s.w / 3, y: max(3, horizon / 5), radius: 2, core: 0xFFF8E2, glow: 0xD4EAFA)
            s.driftingClouds(max(1, s.w / 45), top: 1, bottom: horizon / 2, light: 0xFFFFFF, mid: 0xDCE8F4, shade: 0xA9BED6, seed: 102)
        case .dusk:
            s.sun(x: s.w / 5, y: horizon - 6, radius: 3, core: 0xFFB06A, glow: 0xF07C5C)
        case .night:
            s.stars(above: horizon - 8, density: 0.012, seed: 103)
            s.moonDisc(x: s.w / 4, y: max(3, horizon / 6), radius: s.layout == .window ? 2 : 1)
        }

        // The machine rises behind the city at dusk; by day it's only a shape in the haze.
        let tower = Int(Double(s.w) * 0.62)
        var visorY: Int?
        if s.period != .dawn {
            visorY = machine(&s, x: tower, base: horizon, tones: tones, strip: strip)
        }
        if s.isEvening, let visorY { searchlights(&s, x: tower, y: visorY - 3, horizon: horizon, strip: strip) }

        let farMax = strip ? 6 : min(16, max(7, horizon / 3))
        s.buildings(base: horizon, seed: 104, widths: 2...5, heights: max(3, farMax / 3)...farMax, body: tones.far,
                    lit: tones.lit * 0.4, windows: tones.windows.map { Raster.mix($0, tones.far, 0.45) })
        let nearMax = strip ? 4 : min(10, max(4, horizon / 5))
        s.buildings(base: horizon, seed: 105, widths: 4...9, heights: 2...nearMax, body: tones.near, lit: tones.lit, windows: tones.windows)
        drones(&s, horizon: horizon, tones: tones, tower: tower)

        // The waterfront: a promenade with trees and lamps, then the river.
        s.raster.fillRect(x: 0, y: horizon + 1, width: s.w, height: 2, color: tones.promenade)
        if !strip {
            for (i, x) in stride(from: 4, to: s.w - 4, by: 13).enumerated() {
                Stage.smallTree.draw(on: &s.raster, x: x, y: horizon + 2 - Stage.smallTree.height, palette: tones.tree)
                if s.isEvening, i % 2 == 0 { s.raster.plot(x + 8, horizon - 1, 0xFFD9A0) }
            }
        }
        s.water(top: horizon + 3, bottom: s.h, colors: tones.water, highlight: tones.highlight, seed: 106, density: 0.05)
        if visorY != nil, s.isEvening {
            s.reflection(x: tower, top: horizon + 3, bottom: s.h, color: 0xFF697D, width: 1, seed: 107)
        }
        if s.period == .dusk { s.reflection(x: s.w / 5, top: horizon + 3, bottom: s.h, color: 0xFFB06A, width: 1) }
    }

    /// Stepped machine blocks with red optic strips and one wide visor.
    /// Returns the visor's row.
    static func machine(_ s: inout Stage, x center: Int, base: Int, tones: Tones, strip: Bool) -> Int {
        let scale = strip ? 0.55 : (s.layout == .window ? 1 : 0.7)
        let night = s.isNight, evening = s.isEvening
        func px(_ v: Double) -> Int { max(1, Int((v * scale).rounded())) }
        let bodyW = px(16), bodyH = min(base - 4, px(34))
        let headW = px(22), headH = px(8)
        let left = center - bodyW / 2
        let top = base - bodyH
        // Shoulders, body and head.
        let shoulder = top + headH + px(2)
        s.raster.fillRect(x: center - px(17), y: shoulder + px(4), width: px(34), height: base - shoulder - px(4), color: tones.machine)
        s.raster.fillRect(x: center - px(13), y: shoulder, width: px(26), height: px(4), color: tones.machine)
        s.raster.fillRect(x: left, y: top + headH, width: bodyW, height: bodyH - headH, color: tones.machine)
        s.raster.fillRect(x: left, y: top + headH, width: max(1, bodyW / 4), height: bodyH - headH, color: tones.face)
        s.raster.fillRect(x: center - headW / 2, y: top, width: headW, height: headH, color: tones.machine)
        s.raster.fillRect(x: center - headW / 2, y: top, width: headW, height: 1, color: tones.face)
        // Antennae.
        for dx in [-headW / 3, headW / 3] {
            for y in stride(from: top - px(4), to: top, by: 1) { s.raster.plot(center + dx, y, tones.machine) }
        }
        let visorY = top + headH / 2
        guard evening || s.period == .day else { return visorY }
        // The visor: a long red slit that pulses in slow steps.
        let bright = s.tick(1.5, frames: 2) == 0 || s.still
        let red: UInt32 = night ? (bright ? 0xFF697D : 0xD8485E) : evening ? 0xE85A6E : 0x9A5868
        if night { s.raster.glow(cx: Double(center) + 0.5, cy: Double(visorY), radius: Double(headW) * 0.45, color: 0x8A2A40, strength: 0.35, rings: 2) }
        s.raster.fillRect(x: center - headW / 2 + px(3), y: visorY, width: headW - px(6), height: 1, color: red)
        // Optic strips down the body, on their own slow loops.
        if evening {
            for (k, dx) in [-px(12), -px(4), px(5), px(13)].enumerated() {
                let on = s.still || s.tick(2 + Double(k) * 0.7, frames: 3, offset: Double(k)) != 0
                let length = px(8 + Double(k % 2) * 4)
                for y in stride(from: shoulder + px(6), to: min(base - 1, shoulder + px(6) + length), by: 1) {
                    s.raster.plot(center + dx, y, on ? red : Raster.mix(red, tones.machine, 0.6))
                }
            }
        }
        return visorY
    }

    /// Two violet beams sweeping from the machine's shoulders in slow steps.
    static func searchlights(_ s: inout Stage, x center: Int, y: Int, horizon: Int, strip: Bool) {
        let length = Double(strip ? 10 : y + 6)
        for (k, side) in [-1.0, 1.0].enumerated() {
            let step = s.still ? (k == 0 ? 1 : 3) : s.tick(1.4, frames: 6, offset: Double(k) * 3)
            let sweep = [-0.35, -0.15, 0.05, 0.25, 0.05, -0.15][step]
            let angle = -.pi / 2 + side * 0.35 + sweep * side
            let ox = Double(center) + side * 9, oy = Double(y)
            for i in 2..<Int(length) {
                let half = Double(i) * 0.08 + 0.5
                let f = Double(i) / length
                for j in Int(-half)...Int(half) {
                    let px = ox + cos(angle) * Double(i) + cos(angle + .pi / 2) * Double(j)
                    let py = oy + sin(angle) * Double(i) + sin(angle + .pi / 2) * Double(j)
                    guard py < Double(horizon) - 2 else { continue }
                    s.raster.blendStepped(Int(px), Int(py), 0xD8B5FF, alpha: 0.32 * (1 - f))
                }
            }
        }
    }

    /// Patrols with red eyes, crossing a pixel at a time; at night a brief laser now and then.
    static func drones(_ s: inout Stage, horizon: Int, tones: Tones, tower: Int) {
        let count = [ScenePeriod.dawn: 1, .day: 2, .dusk: 2, .night: 3][s.period] ?? 1
        for i in 0..<count {
            let span = s.w + 20
            let speed = 0.25 + 0.2 * s.hash(i, 1, 108)
            let rightward = i % 2 == 0
            let travel = Int(s.t / speed)
            var x = (Int(s.hash(i, 2, 108) * Double(span)) + (rightward ? travel : -travel)) % span
            if x < 0 { x += span }
            x -= 10
            let y = max(2, Int(Double(horizon) * (0.15 + 0.25 * s.hash(i, 3, 108)))) + s.bob(3, amplitude: 1, offset: Double(i))
            drone.draw(on: &s.raster, x: x - 2, y: y, palette: ["d": tones.drone, "e": 0xFF697D], flipped: !rightward)
            // Brief laser bursts at night, several seconds apart.
            guard s.isNight, !s.still, i == 0 else { continue }
            let cycle = 11.0
            let phase = s.t.truncatingRemainder(dividingBy: cycle)
            if phase < 0.3 {
                let target = (x: Double(x) - 6 + 12 * s.hash(Int(s.t / cycle), i, 109), y: Double(horizon - 2))
                s.raster.line(from: (Double(x) + 0.5, Double(y) + 2), to: target, color: 0xD8B5FF)
                s.raster.glow(cx: target.x, cy: target.y, radius: 3, color: 0xD8B5FF, strength: 0.8, rings: 2)
            }
        }
    }

    static let drone = Sprite([
        ".ddd.",
        "ddedd",
    ])
}

