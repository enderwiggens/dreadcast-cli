import Foundation
import DreadTerminal

/// Superstorm, drawn for the terminal: a tiered green shelf cloud over plains, rain
/// slanting right to left, trees bending, and lightning that lights only its own corner.
/// Deep sky #112934, atmosphere #648A76, signal #D9EF9B, lightning #DFFFCC.
enum Superstorm {
    struct Tones {
        let above: [UInt32]          // sky over the shelf
        let tiers: [UInt32]          // shelf tiers, top to bottom
        let rim: UInt32
        let under: [UInt32]          // light under the shelf to the horizon
        let treeline: UInt32
        let ground: UInt32
        let field: UInt32
        let tree: [Character: UInt32]
        let rain: UInt32
    }

    static func tones(_ period: ScenePeriod) -> Tones {
        switch period {
        case .dawn:
            Tones(above: [0x2A3048, 0x3A4058, 0x4E5268], tiers: [0x3E4A58, 0x4A5862, 0x56666C], rim: 0xA8B4A8,
                  under: [0x6A7472, 0x9A9A88, 0xD8C0A0], treeline: 0x2A3238, ground: 0x24302C, field: 0x2C3A30,
                  tree: ["c": 0x24302C, "C": 0x34423A, "k": 0x161E1C], rain: 0x8A9AA0)
        case .day:
            Tones(above: [0x1C3A44, 0x264850, 0x30565A], tiers: [0x24443C, 0x2E5246, 0x3A6252], rim: 0xB4D0A8,
                  under: [0x3E5E56, 0x6A8A6C, 0xC8DC9C], treeline: 0x1E342E, ground: 0x1E342E, field: 0x2A4A38,
                  tree: ["c": 0x1E3A2E, "C": 0x2E5040, "k": 0x10201A], rain: 0xA8C4B8)
        case .dusk:
            Tones(above: [0x0A171B, 0x10232A, 0x163036], tiers: [0x142A2A, 0x1C3A34, 0x24443C], rim: 0xA2C8A6,
                  under: [0x2C4C44, 0x5A7A5C, 0xBDD894], treeline: 0x0E1E1C, ground: 0x0E1E1C, field: 0x16282A,
                  tree: ["c": 0x0E1E1C, "C": 0x1A3030, "k": 0x081210], rain: 0xA8C4B8)
        case .night:
            Tones(above: [0x050C0E, 0x081416, 0x0C1C1E], tiers: [0x0C1A1C, 0x122624, 0x18302C], rim: 0x5C7A64,
                  under: [0x14262A, 0x2A4438, 0x5C7A5A], treeline: 0x08120F, ground: 0x08120F, field: 0x0C1A18,
                  tree: ["c": 0x08120F, "C": 0x10201C, "k": 0x040A08], rain: 0x7A9A90)
        }
    }

    static func draw(_ s: inout Stage) {
        let tones = tones(s.period)
        let strip = s.layout == .strip
        let ground = strip ? 3 : (s.layout == .window ? 8 : 5)
        let horizon = s.h - ground
        // The shelf hangs low at dawn and fills the sky by dusk.
        let fill: [ScenePeriod: Double] = [.dawn: 0.72, .day: 0.52, .dusk: 0.42, .night: 0.42]
        let shelfBase = Int(Double(horizon) * (fill[s.period] ?? 0.45))

        s.bands(tones.above, bottom: max(1, shelfBase))
        // Under the shelf: darkness, then a narrow slot of light along the horizon.
        s.bands([tones.under[0], tones.under[0], tones.under[0], tones.under[1], tones.under[2]], top: shelfBase, bottom: horizon + 1)
        let flash = flashColumn(s)
        let lips = shelf(&s, base: shelfBase, tones: tones, flashAt: flash?.x)
        let bolt = flash.map { lightning(&s, from: $0, lips: lips, horizon: horizon) }
        if s.period == .dawn { s.birds(3, top: shelfBase + 2, bottom: horizon - 3, color: 0x2A3440) }

        // Distant trees along the horizon, then the field.
        let line = s.ridgeLine(base: horizon, height: strip ? 2 : 3, seed: 81, wavelength: 4)
        s.fill(below: line, to: s.h, color: tones.treeline)
        s.raster.fillRect(x: 0, y: horizon + 1, width: s.w, height: s.h - horizon - 1, color: tones.field)
        for y in stride(from: horizon + 3, to: s.h, by: 3) { s.raster.fillRect(x: 0, y: y, width: s.w, height: 1, color: tones.ground) }
        if let bolt { s.raster.fillRect(x: bolt - 2, y: horizon + 1, width: 5, height: 1, color: Raster.mix(tones.field, 0xDFFFCC, 0.4)) }

        // Wind: rain from the right, trees bending, scraps crossing.
        let intensity: Double = [ScenePeriod.dawn: 0, .day: 0.4, .dusk: 0.8, .night: 1][s.period] ?? 0
        if intensity > 0 { rain(&s, from: shelfBase, to: s.h, intensity: intensity, tones: tones) }
        let bend = intensity == 0 ? 0 : (s.tick(0.7, frames: 2) == 0 || intensity > 0.7 ? 2 : 1)
        if !strip {
            let trees: [(Double, Bool)] = [(0.07, false), (0.15, true), (0.26, false)]
            for (fx, small) in trees {
                let sprite = (small ? smallTrees : bigTrees)[bend]
                sprite.draw(on: &s.raster, x: Int(Double(s.w) * fx), y: horizon + 2 - sprite.height, palette: tones.tree)
            }
        }
        if intensity >= 0.4 { debris(&s, top: shelfBase + 2, bottom: horizon - 1, tones: tones) }
    }

    /// The shelf: one bold dark mass with a smooth underside that slants down toward its
    /// leading edge, a broad roll above a single bright lip, rolling a pixel at a time.
    /// At dawn it is still a low band on the horizon. Returns the lip's row at each column.
    @discardableResult
    static func shelf(_ s: inout Stage, base: Int, tones: Tones, flashAt: Int? = nil) -> [Int] {
        let roll = s.tick(2.5, frames: 1000)
        let rollHeight = s.layout == .window ? 6 : (s.layout == .panorama ? 4 : 3)
        let mass = [Raster.mix(tones.tiers[0], 0x000000, 0.3), tones.tiers[0]]
        var lips: [Int] = []
        for x in 0..<s.w {
            let slant = Int(Double(x) / Double(max(1, s.w)) * 6) - 3
            let wave = Int((1.2 * sin(Double(x + roll) / 11) + 0.6 * sin(Double(x) / 5.3 + 1)).rounded())
            let lip = base + slant + wave
            lips.append(lip)
            let rollEdge = lip - rollHeight + Int((1.0 * sin(Double(x + roll * 2) / 8 + 2)).rounded())
            let top = s.period == .dawn ? max(0, rollEdge - 5 + Int((1.5 * sin(Double(x) / 7 + 1)).rounded())) : 0
            for y in stride(from: top, to: min(s.h, lip), by: 1) {
                var color: UInt32
                if y >= lip - 1 { color = Raster.mix(tones.tiers[2], tones.rim, 0.7) }
                else if y >= lip - 2 { color = Raster.mix(tones.tiers[2], tones.rim, 0.25) }
                else if y >= rollEdge { color = tones.tiers[1] }
                else if y == rollEdge - 1 { color = Raster.mix(tones.tiers[1], tones.rim, 0.3) }
                else { color = y < rollEdge / 2 ? mass[0] : mass[1] }
                if let flashAt, abs(x - flashAt) < 9, y >= rollEdge - 1 {
                    color = Raster.mix(color, 0xDFFFCC, 0.3 * (1 - Double(abs(x - flashAt)) / 9))
                }
                s.raster[x, y] = color
            }
        }
        return lips
    }

    /// One flash every seven to twelve seconds (two cycles at night), posed in still frames.
    static func flashColumn(_ s: Stage) -> (x: Int, variant: Int)? {
        guard s.isEvening else { return nil }
        if s.still { return (s.w * 7 / 10, 0) }
        let cycles: [(seconds: Double, offset: Double, x: Double)] = s.isNight
            ? [(7.3, 0, 0.72), (11.9, 4.1, 0.56)] : [(8.6, 0, 0.72)]
        for (k, cycle) in cycles.enumerated() {
            let phase = (s.t + cycle.offset).truncatingRemainder(dividingBy: cycle.seconds)
            if phase < 0.25 || (phase >= 0.4 && phase < 0.55) {
                return (Int(Double(s.w) * cycle.x), (Int(s.t / cycle.seconds) + k) % 2)
            }
        }
        return nil
    }

    /// A jagged bolt from the shelf's lip to the ground. Returns where it lands.
    static func lightning(_ s: inout Stage, from bolt: (x: Int, variant: Int), lips: [Int], horizon: Int) -> Int {
        var x = bolt.x
        let start = lips[min(s.w - 1, max(0, bolt.x))]
        for y in stride(from: start, through: horizon, by: 1) {
            let step = s.hash(y, bolt.variant, 83)
            x += step < 0.3 ? -1 : step > 0.75 ? 1 : 0
            s.raster.plot(x, y, 0xDFFFCC)
            if s.hash(y, bolt.variant, 84) > 0.93, y < horizon - 3 {
                for i in 1...3 { s.raster.plot(x + i, y + i, 0xB8DCA8) }
            }
        }
        return x
    }

    /// Short diagonal streaks falling right to left, stepping a few times a second.
    static func rain(_ s: inout Stage, from top: Int, to bottom: Int, intensity: Double, tones: Tones) {
        let start = Int(Double(s.w) * (1 - intensity * 0.6))
        // A darker curtain where the rain falls.
        for y in stride(from: top, to: min(s.h, bottom), by: 1) {
            for x in max(0, start - (y - top) / 2)..<s.w { s.raster.blend(x: x, y: y, color: tones.tiers[0], alpha: 0.25 * intensity) }
        }
        let fall = s.tick(0.15, frames: 1000)
        let span = bottom - top
        guard span > 2 else { return }
        for column in stride(from: start - span, to: s.w, by: max(2, Int(5 - 3 * intensity))) {
            let offset = Int(s.hash(column, 0, 85) * Double(span))
            let y0 = top + (offset + fall * 2) % span
            for i in 0..<2 {
                let y = y0 + i
                let x = column + (y - top) / 2 - i
                guard x >= start - 2, y < bottom else { continue }
                s.raster.blend(x: x, y: y, color: tones.rain, alpha: 0.55)
            }
        }
    }

    /// Leaves and scraps crossing right to left.
    static func debris(_ s: inout Stage, top: Int, bottom: Int, tones: Tones) {
        guard bottom > top else { return }
        let step = s.tick(0.12, frames: 100_000)
        for k in 0..<5 {
            let span = s.w + 20
            let x = s.w + 10 - (Int(s.hash(k, 1, 86) * Double(span)) + step * (1 + k % 2)) % span
            let y = top + Int(s.hash(k, 2, 86) * Double(bottom - top)) + (step / 3 + k) % 3 - 1
            s.raster.plot(x, y, k % 3 == 0 ? 0xC8B88A : Raster.mix(tones.tiers[0], tones.rim, 0.5))
        }
    }

    static let bigTrees: [Sprite] = [
        Sprite([
            "...cCc...",
            ".ccCCcc..",
            "cccCcccc.",
            "ccccccccc",
            ".ccccccc.",
            "...ccc...",
            "....k....",
            "....k....",
            "....k....",
        ]),
        Sprite([
            ".cCc.....",
            "ccCCcc...",
            "cccCccc..",
            "cccccccc.",
            ".cccccc..",
            "...ccc...",
            "...k.....",
            "....k....",
            "....k....",
        ]),
        Sprite([
            "cCc......",
            "cCCcc....",
            "ccCccc...",
            "ccccccc..",
            ".ccccc...",
            "..cc.....",
            "..kk.....",
            "...k.....",
            "....k....",
        ]),
    ]

    static let smallTrees: [Sprite] = [
        Sprite([
            "..cc..",
            ".cCcc.",
            "cccccc",
            ".cccc.",
            "..k...",
            "..k...",
        ]),
        Sprite([
            ".cc...",
            "cCcc..",
            "ccccc.",
            ".ccc..",
            "..k...",
            "..k...",
        ]),
        Sprite([
            "cc....",
            "cCc...",
            "cccc..",
            ".cc...",
            ".kk...",
            "..k...",
        ]),
    ]
}
