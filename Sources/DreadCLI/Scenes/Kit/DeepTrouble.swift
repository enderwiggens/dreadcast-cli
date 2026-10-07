import Foundation
import DreadTerminal

/// Deep Trouble, drawn for the terminal: a harbor town, a lighthouse, and something
/// large surfacing in the bay, from a few ripples at dawn to the whole creature by night.
enum DeepTrouble {
    struct Tones {
        let sky: [UInt32]
        let cliff: UInt32
        let hill: UInt32
        let walls: [UInt32]
        let roofs: [UInt32]
        let water: [UInt32]
        let highlight: UInt32
        let rock: UInt32
        let tower: UInt32
        let body: UInt32
        let crown: UInt32
        let sucker: UInt32
        let windows: Double
    }

    static func tones(_ period: ScenePeriod) -> Tones {
        switch period {
        case .dawn:
            Tones(sky: [0x262A5C, 0x3B3C7B, 0x5E5094, 0x926A9C, 0xCC8292, 0xF4A88A], cliff: 0x625A88, hill: 0x3E4A5E,
                  walls: [0xB8A8B8, 0xC4A8A0, 0xA8A8C0], roofs: [0x9A4A4A, 0x5A6E94, 0xA87A4A], water: [0x3A4A80, 0x30406E, 0x26345E],
                  highlight: 0x8A94C0, rock: 0x1E2234, tower: 0xC8C0D0, body: 0x2C6A63, crown: 0x4F9A88, sucker: 0xA8E0CC, windows: 0.3)
        case .day:
            Tones(sky: [0x2E6CC4, 0x3A80D2, 0x4E96DC, 0x6AAEE6, 0x8EC6EE, 0xB8DEF4], cliff: 0x7E9AB8, hill: 0x3E6E4A,
                  walls: [0xEDE2CC, 0xF2D2B0, 0xE2E8EE], roofs: [0xC9584A, 0x6B8FB5, 0xD8A05A], water: [0x2A70B0, 0x245E9C, 0x1E4E88],
                  highlight: 0xC8E8F6, rock: 0x2A3038, tower: 0xF2F2EE, body: 0x2C6A63, crown: 0x4F9A88, sucker: 0xA8E0CC, windows: 0)
        case .dusk:
            Tones(sky: [0x1C1C4A, 0x2E2662, 0x4C2E72, 0x7E3C74, 0xC2566C, 0xF68A62], cliff: 0x4A3A66, hill: 0x2A3040,
                  walls: [0x8A7A8C, 0x9A7C80, 0x7C7A94], roofs: [0x6A3440, 0x3E4A6A, 0x7A5A44], water: [0x2E3466, 0x262C58, 0x1E244A],
                  highlight: 0xB07A8A, rock: 0x161828, tower: 0xD8C8C8, body: 0x245A54, crown: 0x3E8070, sucker: 0x8ACCB8, windows: 0.5)
        case .night:
            Tones(sky: [0x060B20, 0x091230, 0x0D1A3C, 0x122248, 0x182C56, 0x203864], cliff: 0x18203A, hill: 0x0E1624,
                  walls: [0x2A3040, 0x30323E, 0x262C40], roofs: [0x1E1A24, 0x161C28, 0x1E1C20], water: [0x0C1634, 0x0A122C, 0x080E24],
                  highlight: 0x3A4E80, rock: 0x080C16, tower: 0x8A92A8, body: 0x1E4E4A, crown: 0x2E6A60, sucker: 0x5A9A8A, windows: 0.75)
        }
    }

    static func draw(_ s: inout Stage) {
        let tones = tones(s.period)
        let strip = s.layout == .strip
        let water = strip ? 6 : (s.fit == .window ? 20 : 11)
        let sea = s.h - water
        s.bands(tones.sky, bottom: sea + 1)

        let light: (x: Int, y: Int)
        switch s.period {
        case .dawn:
            light = (s.w * 3 / 5, sea)
            s.sun(x: light.x, y: light.y, radius: 2, core: 0xFFE2A8, glow: 0xF8A27C)
            s.driftingClouds(max(1, s.w / 50), top: 1, bottom: sea / 2, light: 0xF6BCA4, mid: 0xB0849E, shade: 0x6E6290, seed: 111)
        case .day:
            light = (s.w * 7 / 10, max(3, sea / 5))
            s.sun(x: light.x, y: light.y, radius: 2, core: 0xFFF8E2, glow: 0xD4EAFA)
            s.driftingClouds(max(1, s.w / 40), top: 1, bottom: sea / 2, light: 0xFFFFFF, mid: 0xDCE8F4, shade: 0xA9BED6, seed: 112)
            s.birds(2, top: sea / 4, bottom: sea * 2 / 3, color: 0x3A4A5A)
        case .dusk:
            light = (s.w * 2 / 3, sea - 1)
            s.sun(x: light.x, y: light.y, radius: 3, core: 0xFFB06A, glow: 0xF07C5C)
            s.driftingClouds(max(1, s.w / 55), top: 2, bottom: sea / 2, light: 0xF6A48A, mid: 0x9C5A78, shade: 0x5E3A62, seed: 113)
        case .night:
            light = (s.w * 4 / 5, max(3, sea / 5))
            s.stars(above: sea - 3, density: 0.014, seed: 114)
            s.moonDisc(x: light.x, y: light.y, radius: s.fit == .window ? 2 : 1)
        }

        // Cliffs across the bay, then the town on its hill.
        let cliffs = s.ridgeLine(base: sea, height: strip ? 2 : 5, seed: 115, wavelength: 20)
        for x in Int(Double(s.w) * 0.3)..<Int(Double(s.w) * 0.74) {
            for y in stride(from: max(0, cliffs[x]), through: sea, by: 1) { s.raster.plot(x, y, tones.cliff) }
        }
        let townLights = town(&s, sea: sea, tones: tones, strip: strip)

        s.water(top: sea + 1, bottom: s.h, colors: tones.water, highlight: tones.highlight, seed: 116, density: 0.05)
        if s.period != .day {
            s.reflection(x: light.x, top: sea + 1, bottom: s.h, color: s.isNight ? 0xC8D0E4 : 0xFFB880, width: 1)
        }
        if s.isEvening {
            for x in townLights { s.reflection(x: x, top: sea + 1, bottom: min(s.h, sea + 5), color: 0xE8B880, width: 0, seed: x) }
        }

        harbor(&s, sea: sea, tones: tones, strip: strip)
        creature(&s, sea: sea, tones: tones, strip: strip)
    }

    // MARK: Town and harbor

    /// Houses climbing the hill on the left, a church at the top. Returns lit window columns.
    static func town(_ s: inout Stage, sea: Int, tones: Tones, strip: Bool) -> [Int] {
        let width = Int(Double(s.w) * 0.32)
        let peak = strip ? 5 : (s.fit == .window ? 18 : 10)
        func ground(_ x: Int) -> Int { sea - Int(Double(peak) * pow(max(0, 1 - Double(x) / Double(width)), 0.8)) }
        for x in 0..<width {
            for y in stride(from: ground(x), through: sea, by: 1) { s.raster.plot(x, y, tones.hill) }
        }
        var lights: [Int] = []
        // Rows of houses, each four or five pixels wide, set into the slope.
        var x = 1
        var i = 0
        while x < width - 3 {
            let w = 4 + Int(s.hash(i, 1, 117) * 2)
            let h = strip ? 2 : 3
            let floor = ground(x + w / 2) + 1
            let wall = tones.walls[i % tones.walls.count], roof = tones.roofs[i % tones.roofs.count]
            s.raster.fillRect(x: x, y: floor - h, width: w, height: h, color: wall)
            s.raster.fillRect(x: x - (strip ? 0 : 1), y: floor - h - 1, width: w + (strip ? 0 : 2), height: 1, color: roof)
            if s.hash(i, 2, 117) < tones.windows {
                s.raster.plot(x + w / 2, floor - h + 1, 0xFFD9A0)
                lights.append(x + w / 2)
            }
            // A second, higher row where the hill is steep.
            if floor - h - 4 > ground(x) + 1, !strip {
                let wall2 = tones.walls[(i + 1) % tones.walls.count]
                s.raster.fillRect(x: x + 1, y: floor - h - 4, width: w - 1, height: h, color: wall2)
                s.raster.fillRect(x: x, y: floor - h - 5, width: w + 1, height: 1, color: tones.roofs[(i + 2) % tones.roofs.count])
                if s.hash(i, 3, 117) < tones.windows { s.raster.plot(x + w / 2, floor - h - 3, 0xFFD9A0) }
            }
            x += w + 1
            i += 1
        }
        if !strip {
            church.draw(on: &s.raster, x: max(1, width / 6), y: ground(width / 6 + 2) - church.height + 1,
                        palette: ["w": tones.walls[0], "r": tones.roofs[2], "s": tones.tower])
        }
        return lights
    }

    /// A breakwater with a lighthouse; at dusk and night its beam sweeps in slow steps.
    static func harbor(_ s: inout Stage, sea: Int, tones: Tones, strip: Bool) {
        let start = Int(Double(s.w) * 0.74)
        s.raster.fillRect(x: start, y: sea - 1, width: s.w - start, height: 3, color: tones.rock)
        let x = Int(Double(s.w) * 0.85)
        let sprite = strip ? smallLighthouse : lighthouse
        let top = sea - 1 - sprite.height
        let lit = s.period != .day
        sprite.draw(on: &s.raster, x: x, y: top, palette: [
            "t": tones.tower, "b": s.period == .day ? 0xC9584A : Raster.mix(tones.tower, 0x000000, 0.35),
            "g": tones.rock, "L": lit ? Ink.lampHot : 0x8AA0B0,
        ])
        if lit, !strip {
            let step = s.tick(0.5, frames: 8)
            let facing = [1.0, 0.7, 0.3, 0, -0.3, -0.7, -1, 0][step]
            let length = Double(s.w) * 0.22 * abs(facing)
            let ox = Double(x) + 2.5, oy = Double(top) + 1.5
            for i in 2..<max(3, Int(length)) {
                let half = Double(i) * 0.16
                for j in Int(-half)...Int(half) {
                    let px = Int(ox + Double(i) * (facing >= 0 ? -1 : 1)), py = Int(oy + Double(j))
                    guard py < sea else { continue }
                    s.raster.blendStepped(px, py, 0xFFE6C4, alpha: 0.55 * (1 - Double(i) / max(1, length)))
                }
            }
        }
        // Boats along the quay, bobbing a pixel.
        if !strip {
            for (k, fx) in [0.08, 0.18, 0.28].enumerated() {
                let bob = s.bob(3.5, amplitude: 1, offset: Double(k) * 0.4)
                boat.draw(on: &s.raster, x: Int(Double(s.w) * fx), y: sea - 1 + bob, palette: [
                    "h": s.isNight ? 0x2A2E3E : [0xC9584A, 0xEDE2CC, 0x4A6A9A][k], "m": s.isNight ? 0x3A3E4E : 0xD8D0C8,
                ])
            }
        }
    }

    // MARK: The creature

    static func creature(_ s: inout Stage, sea: Int, tones: Tones, strip: Bool) {
        let x = Int(Double(s.w) * 0.56)
        let size = strip ? 0.5 : (s.fit == .window ? 1 : 0.7)
        switch s.period {
        case .dawn:
            ripples(&s, x: x, y: sea + 3, size: size)
        case .day:
            tentacle(&s, x: x - Int(4 * size), sea: sea, height: Int(13 * size), thickness: 2.2 * size, tones: tones, phase: 0)
            tentacle(&s, x: x + Int(9 * size), sea: sea, height: Int(7 * size), thickness: 1.6 * size, tones: tones, phase: 2)
            ripples(&s, x: x + Int(3 * size), y: sea + 2, size: size * 0.6)
        case .dusk, .night:
            let arms: [(dx: Double, height: Double, phase: Int)] = s.isNight
                ? [(-17, 14, 0), (-11, 9, 1), (12, 15, 2), (18, 8, 3)] : [(-15, 12, 0), (14, 14, 2)]
            for arm in arms {
                tentacle(&s, x: x + Int(arm.dx * size), sea: sea, height: Int(arm.height * size), thickness: 2.2 * size, tones: tones, phase: arm.phase)
            }
            dome(&s, x: x, sea: sea, size: size, tones: tones)
        }
    }

    /// The head, surfacing a pixel and settling again, with eyes and their reflections.
    static func dome(_ s: inout Stage, x center: Int, sea: Int, size: Double, tones: Tones) {
        let rx = 10 * size, ry = 8 * size
        let rise = Double(s.tick(3.5, frames: 2))
        let cx = Double(center) + 0.5, cy = Double(sea) + 2 - rise
        for py in stride(from: Int(cy - ry), through: sea, by: 1) {
            for px in Int(cx - rx)...Int(cx + rx) {
                let dx = (Double(px) + 0.5 - cx) / rx, dy = (Double(py) + 0.5 - cy) / ry
                guard dx * dx + dy * dy <= 1 else { continue }
                let crown = dx * dx + (dy + 0.55) * (dy + 0.55) * 2.4 < 0.32
                s.raster.plot(px, py, crown ? tones.crown : (s.hash(px, py, 118) < 0.08 ? Raster.mix(tones.body, 0x000000, 0.3) : tones.body))
            }
        }
        // A dark waterline across the body.
        s.raster.fillRect(x: Int(cx - rx), y: sea + 1, width: Int(rx * 2) + 1, height: 1, color: Raster.mix(tones.body, tones.water[0], 0.6))
        let blink = !s.still && s.tick(0.3, frames: 30) == 0
        for side in [-1.0, 1.0] {
            let ex = Int(cx + side * rx * 0.4), ey = Int(cy - ry * 0.25)
            if s.isNight { s.raster.glow(cx: Double(ex) + 0.5, cy: Double(ey) + 0.5, radius: 4 * size + 1, color: 0xF4D487, strength: 0.5, rings: 2) }
            if !blink {
                s.raster.fillRect(x: ex, y: ey, width: size >= 1 ? 2 : 1, height: 1, color: 0xF4D487)
            }
            s.reflection(x: ex, top: sea + 2, bottom: min(s.h, sea + 2 + Int(8 * size)), color: 0xF4D487, width: 0, seed: ex)
        }
    }

    /// An arm rising from the water and curling at the tip, swaying in slow steps.
    static func tentacle(_ s: inout Stage, x base: Int, sea: Int, height: Int, thickness: Double, tones: Tones, phase: Int) {
        guard height >= 3 else { return }
        let sway = Double([0, 1, 2, 1, 0, -1][(s.tick(0.6, frames: 6) + phase) % 6])
        let curl: Double = phase % 2 == 0 ? 1 : -1
        for i in 0...(height * 2) {
            let f = Double(i) / Double(height * 2)
            var x = Double(base) + 0.5 + sin(f * .pi * 0.9 + Double(phase)) * 1.5 * f + sway * f * f
            var y = Double(sea) + 1 - f * Double(height)
            if f > 0.72 {
                let c = (f - 0.72) / 0.28
                x += sin(c * .pi * 0.9) * Double(height) * 0.22 * curl
                y += (1 - cos(c * .pi * 0.9)) * Double(height) * 0.16
            }
            let radius = max(0.5, thickness * (1 - 0.7 * f))
            s.raster.fillCircle(cx: x, cy: y, radius: radius, color: Int(f * 10) % 3 == 0 ? tones.crown : tones.body)
            if i % 4 == 2, f < 0.85, thickness >= 1.5 {
                s.raster.plot(Int(x + radius * curl * -0.8), Int(y), tones.sucker)
            }
        }
    }

    /// Rings spreading on the water, a step at a time.
    static func ripples(_ s: inout Stage, x center: Int, y: Int, size: Double) {
        for k in 0..<2 {
            let grow = (s.tick(0.5, frames: 8) + k * 4) % 8
            let rx = (2 + Double(grow) * 1.4) * max(0.6, size)
            let steps = Int(rx * 6) + 4
            for i in 0..<steps {
                let a = Double(i) / Double(steps) * 2 * .pi
                s.raster.blend(x: Int(Double(center) + cos(a) * rx), y: Int(Double(y) + sin(a) * max(1, rx * 0.3)), color: 0xC8D8F0,
                               alpha: 0.5 * (1 - Double(grow) / 8))
            }
        }
    }

    static let lighthouse = Sprite([
        ".ggg.",
        ".LLL.",
        "ggggg",
        ".ttt.",
        ".bbb.",
        ".ttt.",
        ".bbb.",
        ".ttt.",
        ".bbb.",
        "tttt.",
        "ttttt",
    ])

    static let smallLighthouse = Sprite([
        ".L.",
        "ggg",
        ".t.",
        ".b.",
        "ttt",
    ])

    static let church = Sprite([
        "..s..",
        "..s..",
        ".rrr.",
        ".www.",
        "rrrrr",
        "wwwww",
        "wwwww",
    ])

    static let boat = Sprite([
        "..m...",
        "..mm..",
        "hhhhhh",
        ".hhhh.",
    ])
}
