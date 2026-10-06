import Foundation
import DreadTerminal

/// Solar Tantrum, drawn for the terminal: wind country under mint and lavender
/// aurora, with transformers failing one site at a time. Deep sky #11182F,
/// atmosphere #246471, signal #ADF2D1, aurora #BF92D8.
enum SolarTantrum {
    struct Tones {
        let sky: [UInt32]
        let far: UInt32
        let mid: UInt32
        let near: UInt32
        let metal: UInt32
        let steel: UInt32
    }

    static func tones(_ period: ScenePeriod) -> Tones {
        switch period {
        case .dawn: Tones(sky: [0x262A5C, 0x3B3C7B, 0x5E5094, 0x92669C, 0xCC8292, 0xF4A88A], far: 0x4C5C82, mid: 0x34584E, near: 0x24442F, metal: 0xD8D4E0, steel: 0x6A6A7A)
        case .day: Tones(sky: [0x3068BA, 0x3E7CC8, 0x5292D4, 0x6CA8DE, 0x8CC0E8, 0xB0D6F0], far: 0x6E98B4, mid: 0x4E8E4E, near: 0x3A7A3E, metal: 0xF4F6F8, steel: 0x8A8E96)
        case .dusk: Tones(sky: [0x121A3C, 0x1E2456, 0x342C68, 0x523A72, 0x8C4E6E, 0xD47E66], far: 0x3A3E62, mid: 0x283E44, near: 0x1A2E2A, metal: 0xB8B4C8, steel: 0x4E4A5E)
        case .night: Tones(sky: [0x060A18, 0x091024, 0x0C1830, 0x10223C, 0x153248, 0x1C4454], far: 0x152434, mid: 0x0F2228, near: 0x0A1819, metal: 0x8494AC, steel: 0x2E3646)
        }
    }

    static func draw(_ s: inout Stage) {
        let tones = tones(s.period)
        let strip = s.layout == .strip
        let horizon = s.h - (strip ? 7 : (s.fit == .window ? 16 : 11))
        s.bands(tones.sky, bottom: horizon + 1)

        switch s.period {
        case .dawn:
            s.sun(x: s.w / 6, y: horizon, radius: 2, core: 0xFFE2A8, glow: 0xF8A27C)
            s.driftingClouds(max(1, s.w / 50), top: 1, bottom: horizon / 2, light: 0xF6BCA4, mid: 0xB0849E, shade: 0x6E6290, seed: 61)
        case .day:
            flaringSun(&s, x: s.w / 4, y: max(5, horizon / 3), radius: strip ? 2 : 4)
            s.driftingClouds(max(1, s.w / 45), top: 1, bottom: horizon / 2, light: 0xFFFFFF, mid: 0xDDE8F4, shade: 0xA9BED6, seed: 62)
        case .dusk:
            s.stars(above: horizon / 3, density: 0.008, seed: 63)
            s.sun(x: s.w / 7, y: horizon, radius: 3, core: 0xFFB06A, glow: 0xF07C5C)
            aurora(&s, top: 1, bottom: horizon - 4, strength: 0.75)
        case .night:
            s.stars(above: horizon - 2, density: 0.014, seed: 64)
            aurora(&s, top: 1, bottom: horizon - 3, strength: 1)
        }

        // Three ridges; turbines stand on the middle one, pylons on the nearest.
        let farLine = s.ridgeLine(base: horizon, height: strip ? 2 : 4, seed: 65, wavelength: 45)
        s.fill(below: farLine, to: s.h, color: tones.far)
        districts(&s, line: farLine, tones: tones)
        let midBase = horizon + (strip ? 3 : (s.fit == .window ? 6 : 4))
        let midLine = s.ridgeLine(base: midBase, height: strip ? 2 : 4, seed: 66, wavelength: 30)
        let towers = strip ? 7 : (s.fit == .window ? 15 : 11)
        for (k, fx) in [0.2, 0.47, 0.74].enumerated() {
            let x = Int(Double(s.w) * fx)
            turbine(&s, x: x, base: midLine[min(s.w - 1, x)], height: towers - (k % 2) * 2, tones: tones, phase: k)
        }
        s.fill(below: midLine, to: s.h, color: tones.mid)
        let nearBase = s.h - (strip ? 2 : (s.fit == .window ? 5 : 3))
        let nearLine = s.ridgeLine(base: nearBase, height: strip ? 1 : 3, seed: 67, wavelength: 26)
        s.fill(below: nearLine, to: s.h, color: tones.near)
        if !strip { pylons(&s, line: nearLine, tones: tones) }
    }

    // MARK: Sky

    /// Ribbons of light: a bright mint lower edge with curtains rising from it in smooth
    /// folds, fading through teal to lavender. The folds drift in slow steps.
    static func aurora(_ s: inout Stage, top: Int, bottom: Int, strength: Double) {
        guard bottom > top + 4 else { return }
        let step = Double(s.tick(0.6, frames: 1000))
        let span = Double(bottom - top)
        for k in 0..<2 {
            let kd = Double(k)
            for x in 0..<s.w {
                let fx = Double(x) / Double(s.w)
                let edge = Double(top) + span * (0.42 + 0.26 * kd) + span * 0.16 * sin(fx * 4.4 + kd * 2.3 + step * 0.05)
                // Curtain height folds smoothly along the ribbon.
                let fold = 0.5 + 0.3 * sin(Double(x) * 0.31 + kd * 1.7 + step * 0.21) + 0.2 * sin(Double(x) * 0.093 + step * 0.07)
                let height = Int(span * (0.12 + 0.2 * fold))
                let base = Int(edge)
                for y in stride(from: max(top, base - height), through: min(bottom, base), by: 1) {
                    let d = Double(base - y) / Double(max(1, height))
                    let (color, alpha): (UInt32, Double) = d < 0.25 ? (0xC4FFE4, 0.75) : d < 0.6 ? (0x7ED6BC, 0.5) : (0xBF92D8, 0.35)
                    s.raster.blendStepped(x, y, color, alpha: alpha * strength)
                }
            }
        }
    }

    /// A big sun with prominence loops on its limb: the sun expressing itself.
    static func flaringSun(_ s: inout Stage, x: Int, y: Int, radius: Int) {
        let pulse = s.tick(1.5, frames: 2)
        s.raster.glow(cx: Double(x) + 0.5, cy: Double(y) + 0.5, radius: Double(radius) * 3, color: 0xFFE2A8, strength: 0.45, rings: 3)
        if radius >= 3 {
            for (k, angle) in [-2.3, -0.8, 0.7, 2.4].enumerated() {
                let loop = Double(radius) * 0.5 + Double((k + pulse) % 2)
                let cx = Double(x) + 0.5 + cos(angle) * (Double(radius) + loop * 0.3)
                let cy = Double(y) + 0.5 + sin(angle) * (Double(radius) + loop * 0.3)
                for i in 0..<12 {
                    let a = angle - .pi / 2 + Double(i) / 11 * .pi
                    s.raster.plot(Int(cx + cos(a) * loop), Int(cy + sin(a) * loop), k % 2 == 0 ? 0xFF9A5C : 0xFFC27A)
                }
            }
        }
        s.raster.fillCircle(cx: Double(x) + 0.5, cy: Double(y) + 0.5, radius: Double(radius) + 0.3, color: 0xFFF2CC)
    }

    // MARK: Land

    /// A turbine whose three blades step around in thirds of a turn.
    static func turbine(_ s: inout Stage, x: Int, base: Int, height: Int, tones: Tones, phase: Int) {
        let hub = base - height
        for y in hub..<base { s.raster.plot(x, y, tones.metal) }
        let blade = Double(height) * 0.42
        let frame = s.tick(0.22, frames: 3, offset: Double(phase) * 0.3)
        let start = Double(frame) * (2 * .pi / 9) + Double(phase)
        for k in 0..<3 {
            let a = start + Double(k) * 2 * .pi / 3
            s.raster.line(from: (Double(x) + 0.5, Double(hub) + 0.5),
                          to: (Double(x) + 0.5 + cos(a) * blade, Double(hub) + 0.5 + sin(a) * blade), color: tones.metal)
        }
        s.raster.plot(x, hub, tones.metal)
        if s.isEvening, s.still || s.tick(1, frames: 2, offset: Double(phase) * 0.4) == 0 { s.raster.plot(x, hub - 1, 0xFF4A4A) }
    }

    /// Lights of a distant town that go dark by district as each site fails.
    static func districts(_ s: inout Stage, line: [Int], tones: Tones) {
        guard s.isEvening else { return }
        let start = s.w * 2 / 5, end = s.w * 9 / 10
        for x in stride(from: start, to: end, by: 2) {
            let district = (x - start) * 4 / max(1, end - start)
            guard !outage(s, site: district).dark, s.hash(x, 1, 69) < 0.55 else { continue }
            s.raster.plot(x, line[x] + 1, 0xFFD9A0)
        }
    }

    /// Where each site is in its sixteen-second cycle: a brief flash, then smoke.
    static func outage(_ s: Stage, site: Int) -> (flash: Bool, smoke: Int, dark: Bool) {
        let frames = 64                               // quarter seconds
        let at = s.still ? [5, 26, 1, 44][site % 4] : s.tick(0.25, frames: frames, offset: Double(site) * 4.1)
        return (at < 2, at >= 1 && at < 32 ? at : -1, at >= 1 && at < 28)
    }

    static func pylons(_ s: inout Stage, line: [Int], tones: Tones) {
        let sites = [0.08, 0.3, 0.55, 0.93].map { Int(Double(s.w) * $0) }
        var arms: [(x: Int, y: Int)] = []
        for (k, x) in sites.enumerated() {
            let base = line[min(s.w - 1, x)]
            pylon.draw(on: &s.raster, x: x - pylon.width / 2, y: base - pylon.height + 1, palette: ["p": tones.steel])
            arms.append((x + pylon.width / 2, base - pylon.height + 1))
            guard s.period != .dawn else { continue }
            let state = outage(s, site: k)
            let top = (x: x, y: base - pylon.height)
            if state.flash {
                s.raster.glow(cx: Double(top.x) + 0.5, cy: Double(top.y) + 0.5, radius: 5, color: 0xDFFFF0, strength: 0.7, rings: 2)
                spark.draw(on: &s.raster, x: top.x - 2, y: top.y - 2, palette: ["*": 0xFFFFFF, "+": 0xDFFFF0])
            }
            if state.smoke >= 0 {
                // Thin smoke rising and leaning with the breeze.
                let rise = min(10, state.smoke / 3 + 1)
                for i in 0..<rise {
                    let px = top.x + i / 3 + (i % 3 == 2 ? 1 : 0)
                    s.raster.blendStepped(px, top.y - 1 - i, s.period == .day ? 0x7A808A : 0x4A5466, alpha: 0.7 - Double(i) * 0.06)
                }
            }
        }
        // Lines sag between the arms.
        for k in 0..<(arms.count - 1) {
            let a = arms[k], b = arms[k + 1]
            let span = b.x - a.x
            guard span > 1 else { continue }
            for i in 0...span {
                let f = Double(i) / Double(span)
                let y = Double(a.y) + Double(b.y - a.y) * f + 3 * sin(f * .pi)
                s.raster.plot(a.x + i, Int(y), Raster.mix(tones.steel, tones.near, 0.3))
            }
        }
    }

    static let pylon = Sprite([
        "ppppppp",
        "..ppp..",
        "..p.p..",
        "..ppp..",
        ".p...p.",
        ".pp.pp.",
        ".p.p.p.",
        "p.p.p.p",
        "pp...pp",
    ])

    static let spark = Sprite([
        "..*..",
        ".+++.",
        "*+*+*",
        ".+++.",
        "..*..",
    ])
}
