import Foundation
import DreadTerminal

/// UAP Invasion, drawn for the terminal: a quiet farm under visitors, escalating from a
/// scout light at dawn to a mothership at night. Beams are flat two-tone light.
enum UAPInvasion {
    struct Tones {
        let sky: [UInt32]
        let ridge: UInt32
        let field: UInt32
        let rows: UInt32
        let near: UInt32
        let tree: UInt32
        let farm: [Character: UInt32]
        let fence: UInt32
    }

    static func tones(_ period: ScenePeriod) -> Tones {
        let lit: UInt32 = Ink.lamp
        switch period {
        case .dawn:
            return Tones(sky: [0x2B2458, 0x403570, 0x5C4486, 0x84548E, 0xB46A90, 0xE8928C], ridge: 0x5C5C8C, field: 0x3E6A4C,
                         rows: 0x335C40, near: 0x2A4C34, tree: 0x1E3A2A,
                         farm: ["r": 0x4E4252, "w": 0xC8B8B8, "q": lit, "d": 0x5A4448, "R": 0x6A3038, "B": 0x9A4440,
                                "t": 0xD8C8C0, "s": 0x9A96A0, "S": 0x7A7684, "k": 0x2A2230],
                         fence: 0x4A3A34)
        case .day:
            return Tones(sky: [0x3672C2, 0x4682CC, 0x5A94D6, 0x74A8DE, 0x92BEE8, 0xB4D4F0], ridge: 0x7092B8, field: 0x5EA24E,
                         rows: 0x4C8E40, near: 0x3E7C36, tree: 0x2C6232,
                         farm: ["r": 0x5A4A50, "w": 0xEEE8DC, "q": 0x8AA8C8, "d": 0x7A5A48, "R": 0x7A3234, "B": 0xB04A3E,
                                "t": 0xF2EEE6, "s": 0xC4C4BC, "S": 0x9C9C96, "k": 0x3A3A40],
                         fence: 0x8A6A4A)
        case .dusk:
            return Tones(sky: [0x1C1C4A, 0x2E265E, 0x4A2E6C, 0x6E3670, 0x9C406C, 0xD0546A, 0xF8806A], ridge: 0x3E3462, field: 0x2C4A3A,
                         rows: 0x243E30, near: 0x1C3226, tree: 0x14281E,
                         farm: ["r": 0x3A2E3E, "w": 0x9A8A96, "q": lit, "d": 0x4A3440, "R": 0x4E2430, "B": 0x7A3038,
                                "t": 0xB8A8AC, "s": 0x7A7484, "S": 0x5A5666, "k": 0x1E1826],
                         fence: 0x3A2C2C)
        case .night:
            return Tones(sky: [0x060A20, 0x091028, 0x0C1634, 0x111D42, 0x16254E, 0x1C2E5A], ridge: 0x18213E, field: 0x10241E,
                         rows: 0x0C1E18, near: 0x0A1814, tree: 0x08140F,
                         farm: ["r": 0x1A1C2C, "w": 0x3A4050, "q": lit, "d": 0x22242E, "R": 0x24161E, "B": 0x3A1E26,
                                "t": 0x5A5A64, "s": 0x3A3E4C, "S": 0x2A2E3A, "k": 0x10121A],
                         fence: 0x241C1C)
        }
    }

    static func draw(_ s: inout Stage) {
        let tones = tones(s.period)
        let strip = s.layout == .strip
        let fenceHeight = strip ? 3 : 5
        let fieldDepth = strip ? 4 : (s.layout == .window ? 9 : 6)
        let fenceTop = s.h - s.deskHeight - fenceHeight
        let horizon = fenceTop - fieldDepth
        s.bands(tones.sky, bottom: horizon + 1)

        switch s.period {
        case .dawn:
            s.sun(x: s.w * 4 / 5, y: horizon - 1, radius: 2, core: 0xFFE2A8, glow: 0xF8A27C)
            s.driftingClouds(max(1, s.w / 45), top: 1, bottom: horizon / 2, light: 0xF4B8A0, mid: 0xB27A98, shade: 0x6E5A8A, seed: 41)
        case .day:
            s.sun(x: s.w * 6 / 7, y: max(3, horizon / 4), radius: 2, core: 0xFFF8E2, glow: 0xD6EAF8)
            s.driftingClouds(max(1, s.w / 35), top: 1, bottom: horizon / 2, light: 0xFFFFFF, mid: 0xDDE8F4, shade: 0xA9BED6, seed: 42)
        case .dusk:
            s.sun(x: s.w * 4 / 5, y: horizon - 1, radius: 3, core: 0xFFA86A, glow: 0xF06A60)
            s.driftingClouds(max(1, s.w / 45), top: 2, bottom: horizon / 2, light: 0xF08A80, mid: 0x8A4A72, shade: 0x4E3062, seed: 43)
        case .night:
            s.stars(above: horizon - 4, density: 0.016, seed: 44)
            s.moonDisc(x: s.w * 2 / 5, y: max(3, horizon / 5), radius: s.layout == .window ? 2 : 1)
        }

        // Distant ridge, fields with crop rows, then the farm on the left.
        let ridgeMax = strip ? 3 : (s.layout == .window ? 7 : 4)
        for x in 0..<s.w {
            let f = Double(x) / 37
            let height = Int((Double(ridgeMax) * (0.55 + 0.3 * sin(f * 1.7 + 0.6) + 0.15 * sin(f * 4.3))).rounded())
            for y in (horizon - height)...horizon { s.raster.plot(x, y, tones.ridge) }
        }
        s.raster.fillRect(x: 0, y: horizon + 1, width: s.w, height: fenceTop - horizon - 1, color: tones.field)
        for y in stride(from: horizon + 2, to: fenceTop, by: 2) {
            s.raster.fillRect(x: 0, y: y, width: s.w, height: 1, color: tones.rows)
        }
        farm(&s, base: horizon + 2, tones: tones)

        // The visitors.
        let ground = horizon + fieldDepth / 2 + 1
        let sky = horizon
        switch s.period {
        case .dawn:
            scout(&s, x: s.w * 3 / 5, y: max(2, sky / 3))
        case .day:
            scout(&s, x: s.w * 2 / 5, y: max(2, sky / 5))
            craft(&s, sprite: saucer, x: s.w * 7 / 10, y: max(1, sky * 2 / 7), ground: ground, phase: 0)
        case .dusk:
            craft(&s, sprite: saucer, x: s.w * 11 / 20, y: max(1, sky / 3), ground: ground, phase: 1.3)
            craft(&s, sprite: saucer, x: s.w * 4 / 5, y: max(1, sky / 5), ground: ground, phase: 0)
        case .night:
            if strip {
                craft(&s, sprite: saucer, x: s.w * 2 / 3, y: 1, ground: ground, phase: 0)
            } else {
                craft(&s, sprite: saucer, x: s.w * 9 / 20, y: max(1, sky * 2 / 5), ground: ground, phase: 1.3)
                craft(&s, sprite: mothership, x: s.w * 7 / 10, y: max(1, sky / 6), ground: ground, phase: 0, rings: true)
            }
        }

        // Fence in the foreground, then the desk.
        s.raster.fillRect(x: 0, y: fenceTop, width: s.w, height: s.h - fenceTop, color: tones.near)
        s.raster.fillRect(x: 0, y: fenceTop + 1, width: s.w, height: 1, color: tones.fence)
        if fenceHeight >= 5 { s.raster.fillRect(x: 0, y: fenceTop + 3, width: s.w, height: 1, color: tones.fence) }
        for x in stride(from: 2, to: s.w, by: 7) {
            s.raster.fillRect(x: x, y: fenceTop, width: 1, height: fenceHeight, color: tones.fence)
        }
        s.desk()
    }

    // MARK: The farm

    static func farm(_ s: inout Stage, base: Int, tones: Tones) {
        let x0 = max(2, s.w / 9)
        tree.draw(on: &s.raster, x: x0 - 8, y: base - tree.height, palette: ["c": tones.tree, "k": Raster.mix(tones.tree, 0x000000, 0.4)])
        house.draw(on: &s.raster, x: x0, y: base - house.height, palette: tones.farm)
        silo.draw(on: &s.raster, x: x0 + 13, y: base - silo.height, palette: tones.farm)
        barn.draw(on: &s.raster, x: x0 + 18, y: base - barn.height, palette: tones.farm)
        smallTree.draw(on: &s.raster, x: x0 + 33, y: base - smallTree.height, palette: ["c": tones.tree, "k": Raster.mix(tones.tree, 0x000000, 0.4)])
        tree.draw(on: &s.raster, x: s.w - 22, y: base - tree.height, palette: ["c": tones.tree, "k": Raster.mix(tones.tree, 0x000000, 0.4)])
    }

    static let house = Sprite([
        "....rrr....",
        "...rrrrr...",
        "..rrrrrrr..",
        ".rrrrrrrrr.",
        "rrrrrrrrrrr",
        ".wwwwwwwww.",
        ".wqwwwwwqw.",
        ".wwwwddwww.",
        ".wwwwddwww.",
    ])

    static let silo = Sprite([
        ".ss.",
        "ssss",
        "sSss",
        "ssss",
        "sSss",
        "ssss",
        "sSss",
        "ssss",
        "sSss",
        "ssss",
        "sSss",
        "ssss",
    ])

    static let barn = Sprite([
        "....RRRRR.....",
        "..RRRRRRRRR...",
        ".RRRRRRRRRRR..",
        "RRRRRRRRRRRRR.",
        ".BBBBBBBBBBB..",
        ".BBBtttttBBB..",
        ".BBBtBtBtBBB..",
        ".BBBttBttBBB..",
        ".BBBtBtBtBBB..",
        ".BBBtttttBBB..",
    ])

    static let tree = Sprite([
        "..ccc..",
        ".ccccc.",
        "ccccccc",
        "ccccccc",
        ".ccccc.",
        "...k...",
        "...k...",
    ])

    static let smallTree = Sprite([
        ".ccc.",
        "ccccc",
        ".ccc.",
        "..k..",
    ])

    // MARK: The visitors

    static let saucer = Sprite([
        "......ggg......",
        "....gGGgggg....",
        "..hhhhhhhhhhh..",
        "hhHHHHHHHHHhhhh",
        "lllllllllllllll",
        ".uuuuuuuuuuuuu.",
        "....uuuuuuu....",
    ])

    static let mothership = Sprite([
        "...........ggggggggg...........",
        ".........gGGGGgggggggg.........",
        "......hhhhhhhhhhhhhhhhhhh......",
        "...hhhHHHHHHHHHHHHHHHHHHhhhh...",
        ".hhhHHHHHHHHHHHHHHHHHHHHHHHhhh.",
        "lllllllllllllllllllllllllllllll",
        ".uuuuuuuuuuuuuuuuuuuuuuuuuuuuu.",
        "...uuuuuuuuuuuuuuuuuuuuuuuuu...",
        "........uuuuuuuuuuuuuuu........",
    ])

    static func hull(_ s: Stage) -> [Character: UInt32] {
        s.isNight
            ? ["g": 0x5ACFA6, "G": 0xB8FFE4, "h": 0x5A6478, "H": 0x7A8498, "l": 0x2A3040, "u": 0x3A4254]
            : ["g": 0x7ADFBE, "G": 0xD8FFF0, "h": 0x8A94A8, "H": 0xC4CCD8, "l": 0x3A4254, "u": 0x5A6478]
    }

    /// A distant scout: a fleck of hull with a light that blinks.
    static func scout(_ s: inout Stage, x: Int, y: Int) {
        let palette = hull(s)
        s.raster.fillRect(x: x - 1, y: y, width: 3, height: 1, color: palette["H"]!)
        s.raster.plot(x, y - 1, palette["g"]!)
        s.raster.plot(x, y + 1, s.tick(0.8, frames: 2) == 0 ? Ink.lamp : palette["l"]!)
    }

    /// A craft that bobs a pixel, chases lights around its rim and holds a beam on the field.
    static func craft(_ s: inout Stage, sprite: Sprite, x center: Int, y top: Int, ground: Int, phase: Double, rings: Bool = false) {
        let y = top + s.bob(4.5, amplitude: 1, offset: phase)
        let x = center - sprite.width / 2
        let beamTop = y + sprite.height - 1
        if ground > beamTop + 1 {
            beam(&s, x: center, top: beamTop, bottom: ground, halfTop: sprite.width / 4, halfBottom: sprite.width / 2 + 2, phase: phase)
            if rings { groundRings(&s, x: center, y: ground, radius: sprite.width / 2 + 3) }
        }
        sprite.draw(on: &s.raster, x: x, y: y, palette: hull(s))
        // Rim lights chase around the band.
        let rim = (0..<sprite.height).first { row in (0..<sprite.width).contains { sprite.key($0, row) == "l" } } ?? 0
        let step = s.tick(0.3, frames: 3, offset: phase)
        for column in stride(from: 1, to: sprite.width - 1, by: 3) {
            let on = (column / 3 + step) % 3 == 0
            s.raster.plot(x + column, y + rim, on ? Ink.lamp : (s.isNight ? 0x8AF0C8 : 0xD8E0EA))
        }
    }

    /// Flat two-tone light: a brighter core, a fainter skirt, a scan line sweeping down.
    static func beam(_ s: inout Stage, x center: Int, top: Int, bottom: Int, halfTop: Int, halfBottom: Int, phase: Double) {
        let height = bottom - top
        let scan = top + s.tick(0.12, frames: max(1, height + 8), offset: phase * 3)
        for y in top...bottom {
            let f = Double(y - top) / Double(max(1, height))
            let half = Double(halfTop) + Double(halfBottom - halfTop) * f
            for x in Int(Double(center) - half)...Int(Double(center) + half) {
                let edge = abs(Double(x) + 0.5 - Double(center)) / max(0.5, half)
                var alpha = edge < 0.45 ? 0.38 : 0.2
                if edge > 0.9 { alpha = 0.32 }
                if y == scan { alpha += 0.2 }
                s.raster.blend(x: x, y: y, color: edge < 0.45 ? 0xB8FFE0 : 0x9CF0C8, alpha: alpha)
            }
        }
        s.raster.fillEllipse(cx: Double(center) + 0.5, cy: Double(bottom) + 0.5, rx: Double(halfBottom) + 1, ry: 1.2, color: 0x9CF0C8, alpha: 0.4)
    }

    /// Rings spreading across the field, a pixel at a time.
    static func groundRings(_ s: inout Stage, x center: Int, y: Int, radius: Int) {
        for k in 0..<2 {
            let grow = (s.tick(0.4, frames: 12) + k * 6) % 12
            let rx = Double(radius) + Double(grow) * 1.5
            let ry = max(1, rx * 0.2)
            let steps = Int(rx * 7)
            for i in 0..<steps {
                let a = Double(i) / Double(steps) * 2 * .pi
                s.raster.blend(x: Int(Double(center) + cos(a) * rx), y: Int(Double(y) + sin(a) * ry), color: 0x9CF0C8,
                               alpha: 0.6 * (1 - Double(grow) / 12))
            }
        }
    }
}
