import Foundation
import DreadTerminal

/// Clear for Now, drawn for the terminal: a quiet cove with palms and a bench.
/// Nothing happens. That is the joke.
enum ClearForNow {
    struct Tones {
        let sky: [UInt32]
        let land: UInt32
        let sea: [UInt32]
        let highlight: UInt32
        let glint: UInt32
        let sand: UInt32
        let wet: UInt32
        let foam: UInt32
        let palm: [Character: UInt32]
        let bench: UInt32
    }

    static func tones(_ period: ScenePeriod) -> Tones {
        switch period {
        case .dawn:
            Tones(sky: [0x2A2A5E, 0x41397A, 0x654C90, 0x9A6296, 0xD07E90, 0xF6A68A], land: 0x5C5C86,
                  sea: [0x3E4E88, 0x46608E, 0x4E7494], highlight: 0x9AA6C8, glint: 0xFFD0A0, sand: 0xE4C2A2, wet: 0xC09C8C,
                  foam: 0xF2E8EE, palm: ["f": 0x2A3A3A, "F": 0x3E5248, "t": 0x4A3A3A, "T": 0x6A5248, "c": 0x3A2A2A], bench: 0x5A4440)
        case .day:
            Tones(sky: [0x2E6CC4, 0x3A80D2, 0x4E96DC, 0x6AAEE6, 0x8EC6EE, 0xB8DEF4], land: 0x6E96B4,
                  sea: [0x1E6EB0, 0x2A8ABE, 0x3EB0C8], highlight: 0xC8EEF6, glint: 0xFFFFFF, sand: 0xF2DCA8, wet: 0xD8BC88,
                  foam: 0xFFFFFF, palm: ["f": 0x2E7A3E, "F": 0x4A9A4C, "t": 0x7A5A3E, "T": 0x9A7A56, "c": 0x5A3E2A], bench: 0x8A6A4A)
        case .dusk:
            Tones(sky: [0x1C1C4A, 0x2E2662, 0x4C2E72, 0x7E3C74, 0xC2566C, 0xF68A62], land: 0x40365E,
                  sea: [0x2A3A6A, 0x34486E, 0x3E5672], highlight: 0xC88A88, glint: 0xFFA86A, sand: 0xD4A48A, wet: 0xA87A72,
                  foam: 0xF0D8D0, palm: ["f": 0x1E2A2E, "F": 0x2E3E3E, "t": 0x3A2A2A, "T": 0x54403A, "c": 0x2A1E1E], bench: 0x3E2E2E)
        case .night:
            Tones(sky: [0x060B1E, 0x0A1228, 0x0E1834, 0x132040, 0x1A2A4E, 0x22365C], land: 0x18223A,
                  sea: [0x0C1838, 0x10203E, 0x142846], highlight: 0x4A5E8A, glint: 0xDCE2F0, sand: 0x5A6074, wet: 0x464C60,
                  foam: 0x8A96B0, palm: ["f": 0x0C1418, "F": 0x16222A, "t": 0x1A1616, "T": 0x262022, "c": 0x100C0C], bench: 0x1E1A1E)
        }
    }

    static func draw(_ s: inout Stage) {
        let tones = tones(s.period)
        let strip = s.layout == .strip
        let beach = strip ? 4 : (s.fit == .window ? 11 : 7)
        let sea = strip ? 5 : (s.fit == .window ? 11 : 7)
        let shore = s.h - beach
        let horizon = shore - sea
        s.bands(tones.sky, bottom: horizon + 1)

        let light: (x: Int, y: Int)
        switch s.period {
        case .dawn:
            light = (s.w * 11 / 20, horizon)
            s.sun(x: light.x, y: light.y, radius: 2, core: 0xFFE2A8, glow: 0xF8A27C)
            s.driftingClouds(max(1, s.w / 45), top: 1, bottom: horizon / 2, light: 0xF6BCA4, mid: 0xB0849E, shade: 0x7A6A96, seed: 51)
            s.birds(2, top: horizon / 4, bottom: horizon / 2, color: 0x3A3050)
        case .day:
            light = (s.w * 9 / 20, max(3, horizon / 4))
            s.sun(x: light.x, y: light.y, radius: 2, core: 0xFFFCEE, glow: 0xE0F2FC)
            s.driftingClouds(max(1, s.w / 40), top: 1, bottom: horizon / 2, light: 0xFFFFFF, mid: 0xE4EEF8, shade: 0xB4C8DE, seed: 52)
            s.birds(3, top: horizon / 4, bottom: horizon * 2 / 3, color: 0x3A4A5A)
        case .dusk:
            light = (s.w * 3 / 5, horizon)
            s.sun(x: light.x, y: light.y, radius: 3, core: 0xFFB06A, glow: 0xF07C5C)
            s.driftingClouds(max(1, s.w / 55), top: 2, bottom: horizon / 2, light: 0xF6A48A, mid: 0x9C5A78, shade: 0x5E3A62, seed: 53)
        case .night:
            light = (s.w * 7 / 10, max(3, horizon / 4))
            s.stars(above: horizon - 2, density: 0.016, seed: 54)
            s.moonDisc(x: light.x, y: light.y, radius: s.fit == .window ? 2 : 1)
        }

        // Headlands either side of the bay.
        let tall = strip ? 3 : (s.fit == .window ? 8 : 5)
        for x in 0..<s.w {
            let left = 1 - Double(x) / (Double(s.w) * 0.3)
            let right = (Double(x) - Double(s.w) * 0.74) / (Double(s.w) * 0.26)
            let lift = max(left, right * 0.8)
            guard lift > 0 else { continue }
            let height = Int((Double(tall) * min(1, lift * 1.4) + sin(Double(x) * 0.4) * 0.6).rounded())
            for y in stride(from: max(0, horizon - height), through: horizon, by: 1) { s.raster.plot(x, y, tones.land) }
        }

        // The sea, the light on it, then the beach.
        s.water(top: horizon + 1, bottom: shore + 3, colors: tones.sea, highlight: tones.highlight, seed: 55, density: 0.05)
        s.reflection(x: light.x, top: horizon + 1, bottom: shore, color: tones.glint, width: 1)
        let line = (0..<s.w).map { x -> Int in
            shore + Int((1.6 * sin(Double(x) / Double(s.w) * .pi * 0.9 + 0.2) - Double(x) / Double(s.w) * 2).rounded())
        }
        let reach = s.tick(1.4, frames: 3)
        for x in 0..<s.w {
            for y in max(0, line[x])..<s.h {
                let wet = y < line[x] + 2
                let speck = s.hash(x, y, 56) > 0.93
                s.raster.plot(x, y, wet ? tones.wet : (speck ? tones.wet : tones.sand))
            }
            // Foam where the waves arrive, moving in and out a pixel at a time.
            let foam = line[x] - 1 + (reach == 1 ? 1 : 0)
            s.raster.plot(x, foam, tones.foam)
            if reach != 2, s.hash(x, 3, 57) > 0.55 { s.raster.plot(x, foam - 1, Raster.mix(tones.foam, tones.sea[2], 0.5)) }
        }

        // A bench on the left; palms on the right, fronds stirring.
        if !strip {
            bench.draw(on: &s.raster, x: s.w / 10, y: line[s.w / 10] + beach / 2 - 2, palette: ["b": tones.bench])
        }
        let sway = s.tick(1.3, frames: 2)
        let palms: [(Double, Bool)] = strip ? [(0.86, false)] : [(0.8, false), (0.88, true)]
        for (fx, flipped) in palms {
            let x = Int(Double(s.w) * fx)
            let sprite = sway == 0 ? palm : palmSway
            let base = min(s.h, line[min(s.w - 1, x)] + (strip ? 3 : 4))
            sprite.draw(on: &s.raster, x: x - sprite.width / 2, y: base - sprite.height, palette: tones.palm, flipped: flipped)
        }
    }

    static let palm = Sprite([
        "..ff.......ff...",
        ".fFff.....ffFf..",
        "ff..fff.fff..ff.",
        "f...ffFFFff....f",
        "...ff.fcf.ff....",
        "..f...cTc..ff...",
        "......tT.....f..",
        "......tT........",
        ".....tT.........",
        ".....tT.........",
        ".....tT.........",
        "....tT..........",
        "....tT..........",
        "....tT..........",
        "...ttTt.........",
    ])

    static let palmSway = Sprite([
        "...ff.......ff..",
        "..fFff.....ffFf.",
        ".ff..fff.fff..ff",
        "f....ffFFFff...f",
        "...ff.fcf.ff....",
        "..f...cTc..ff...",
        "......tT......f.",
        "......tT........",
        ".....tT.........",
        ".....tT.........",
        ".....tT.........",
        "....tT..........",
        "....tT..........",
        "....tT..........",
        "...ttTt.........",
    ])

    static let bench = Sprite([
        "bbbbbbb",
        ".......",
        "bbbbbbb",
        "b.....b",
    ])
}
