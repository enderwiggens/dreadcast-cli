import Foundation
import DreadTerminal

// Solar Tantrum, Superstorm and UAP Invasion: open country, large skies.
extension SceneCanvas {
    /// Rounds a blend amount to a few flat levels: pixel-art shading that also keeps
    /// animated frames small, since tiny drifts no longer change every pixel.
    static func step(_ amount: Double, levels: Double = 8) -> Double { (amount * levels).rounded() / levels }

    func valueNoise(_ x: Double, _ y: Double, seed: Int) -> Double {
        let xi = Int(floor(x)), yi = Int(floor(y))
        let xf = x - floor(x), yf = y - floor(y)
        let sx = xf * xf * (3 - 2 * xf), sy = yf * yf * (3 - 2 * yf)
        let a = hash(xi, yi, seed), b = hash(xi + 1, yi, seed), c = hash(xi, yi + 1, seed), d = hash(xi + 1, yi + 1, seed)
        let top = a + (b - a) * sx, bottom = c + (d - c) * sx
        return top + (bottom - top) * sy
    }

    func fbm(_ x: Double, _ y: Double, seed: Int) -> Double {
        0.5 * valueNoise(x, y, seed: seed) + 0.3 * valueNoise(x * 2.1, y * 2.1, seed: seed + 1) + 0.2 * valueNoise(x * 4.3, y * 4.3, seed: seed + 2)
    }

    // MARK: Solar Tantrum

    /// Mint and lavender aurora over wind country, with small staggered electrical failures.
    mutating func solarTantrum() {
        let horizon = Int(Y(0.64))
        var stops = Self.sky(period)
        switch period {
        case .dusk: stops = [0x131A3C, 0x20245A, 0x372E6A, 0x553A72, 0x91526E, 0xE08664]
        case .night: stops = [0x060A18, 0x091024, 0x0D1830, 0x11213C, 0x173246, 0x1E4654]
        default: break
        }
        sky(stops, to: horizon + n(3))
        switch period {
        case .dawn:
            sun(x: X(0.14), y: Double(horizon), radius: max(1.5, 2 * u), core: 0xFFE2A8, glow: 0xFFB27A)
            driftingClouds(count: 3, top: 0.06, bottom: 0.4, size: 11, light: 0xF6BCA4, mid: 0xB0849E, shade: 0x6E6290, seed: 72, speed: 0.5)
        case .day:
            flaringSun(x: X(0.27), y: Y(0.22), radius: max(1.6, 2.6 * u))
            driftingClouds(count: 3, top: 0.05, bottom: 0.4, size: 11, light: 0xFFFFFF, mid: 0xDCE8F4, shade: 0xA9BED6, seed: 71)
        case .dusk:
            stars(until: Int(Y(0.3)), density: 0.006, seed: 24)
            sun(x: X(0.12), y: Double(horizon), radius: max(2, 2.4 * u), core: 0xFFB06A, glow: 0xF07C5C)
            aurora(strength: 0.75, top: 0.0, bottom: 0.5)
        case .night:
            stars(until: horizon, density: 0.013, seed: 23)
            aurora(strength: 1, top: 0.0, bottom: 0.56)
        }

        let land: (far: UInt32, mid: UInt32, near: UInt32, metal: UInt32) = switch period {
        case .dawn: (0x4A5E7A, 0x34584E, 0x22402F, 0xD8D4E0)
        case .day: (0x6A9AB0, 0x4E8E4E, 0x3A7A3E, 0xF4F6F8)
        case .dusk: (0x3A3E62, 0x283E44, 0x1A2E2A, 0xB8B4C8)
        case .night: (0x152434, 0x0F2228, 0x0A1819, 0x8494AC)
        }
        let far = hills(base: Y(0.66), amplitude: Y(0.025), seed: 31, frequency: 0.8)
        fillBelow(far, color: land.far)
        // A distant town that loses power by district.
        let districts = 4
        for i in 0..<Int(X(0.5) / Double(n(2))) {
            let x = Int(X(0.42)) + i * n(2)
            guard x < w else { break }
            let district = min(districts - 1, i * districts / max(1, Int(X(0.5) / Double(n(2)))))
            let out = isEvening && outage(site: district).dark
            let top = Int(far[min(w - 1, x)]) - n(1 + 1.5 * hash(i, 1, 73))
            raster.fillRect(x: x, y: top, width: n(1.5), height: Int(far[min(w - 1, x)]) - top + 1, color: Raster.mix(land.far, 0x000000, 0.25))
            if isEvening, !out, hash(i, 2, 73) < 0.6 { raster.plot(x, top + 1, 0xFFD9A0) }
        }

        let mid = hills(base: Y(0.77), amplitude: Y(0.04), seed: 32, frequency: 1.1)
        for (k, fx) in [0.2, 0.47, 0.74].enumerated() {
            let x = Int(X(fx))
            turbine(x: Double(x), base: mid[min(w - 1, max(0, x))], height: Y(0.27 - 0.03 * Double(k % 2)), color: land.metal,
                    speed: 0.9 + 0.25 * Double(k), phase: Double(k) * 1.3)
        }
        fillBelow(mid, color: land.mid)
        let near = hills(base: Y(0.9), amplitude: Y(0.035), seed: 33, frequency: 0.9)
        fillBelow(near, color: land.near)

        // Pylons and lines across the near hills; each site fails once per sixteen seconds.
        let sites = [0.08, 0.3, 0.52, 0.94]
        var tips: [(x: Double, y: Double)] = []
        for (k, fx) in sites.enumerated() {
            let x = X(fx)
            let base = near[min(w - 1, Int(x))]
            tips.append(pylon(x: x, base: base, height: Y(0.17), color: Raster.mix(land.metal, land.near, 0.45)))
            if period != .dawn { failure(site: k, x: x, y: base - Y(0.17)) }
        }
        for k in 0..<(tips.count - 1) {
            wire(from: tips[k], to: tips[k + 1], sag: Y(0.04), color: Raster.mix(land.metal, land.near, 0.6))
        }
        // A small cabin, with the lamp on.
        let cabinX = Int(X(0.66)), cabinBase = Int(near[cabinX].rounded())
        let cabinW = n(5, minimum: 4), cabinH = n(3, minimum: 2)
        let wall: UInt32 = period == .day ? 0x8A6A52 : 0x2A2026
        polygon([(Double(cabinX) - 1, Double(cabinBase - cabinH)), (Double(cabinX + cabinW / 2), Double(cabinBase - cabinH - n(2))),
                 (Double(cabinX + cabinW) + 1, Double(cabinBase - cabinH))], color: Raster.mix(wall, 0x000000, 0.35))
        raster.fillRect(x: cabinX, y: cabinBase - cabinH, width: cabinW, height: cabinH + 1, color: wall)
        lampWindow(x: cabinX + cabinW / 2, y: cabinBase - cabinH + 1, size: n(1.2))
    }

    /// Which part of the sixteen-second cycle a site is in.
    func outage(site: Int) -> (flash: Double, smoke: Double, dark: Bool) {
        let cycle = 16.0
        let phase = still ? [1.2, 6.5, 0.3, 11.0][site % 4] : (t + Double(site) * 4.1).truncatingRemainder(dividingBy: cycle)
        let flash = phase < 0.6 ? 1 - phase / 0.6 : 0
        let smoke = phase >= 0.3 && phase < 9 ? (phase - 0.3) / 8.7 : -1
        return (flash, smoke, phase >= 0.3 && phase < 7)
    }

    mutating func failure(site: Int, x: Double, y: Double) {
        let state = outage(site: site)
        let strength = period == .day ? 0.6 : 1
        if state.flash > 0 {
            raster.glow(cx: x, cy: y, radius: Double(n(4, minimum: 2)), color: 0xDFFFF0, strength: state.flash * strength)
            raster.plot(Int(x), Int(y), 0xFFFFFF)
        }
        if state.smoke >= 0 {
            // Thin smoke rising and leaning with the breeze.
            let height = Y(0.22) * min(1, state.smoke * 1.6)
            let steps = Int(height)
            for i in 0..<max(1, steps) {
                let f = Double(i) / max(1, height)
                let sx = x + f * Y(0.06) + sin(f * 6 + t) * 0.6
                raster.blendStepped(Int(sx), Int(y - Double(i)), period == .day ? 0x7A808A : 0x4A5466, alpha: 0.7 * (1 - f) * (1 - state.smoke * 0.6))
            }
        }
    }

    mutating func turbine(x: Double, base: Double, height th: Double, color: UInt32, speed: Double, phase: Double) {
        let hubY = base - th
        for y in Int(hubY)..<Int(base) { raster.plot(Int(x), y, color) }
        if th > 14 { for y in Int(hubY + th * 0.35)..<Int(base) { raster.plot(Int(x) + 1, y, Raster.mix(color, 0x000000, 0.35)) } }
        let blade = th * 0.46
        let angle = phase + t * speed
        for k in 0..<3 {
            let a = angle + Double(k) * 2 * .pi / 3
            raster.line(from: (x + 0.5, hubY + 0.5), to: (x + 0.5 + cos(a) * blade, hubY + 0.5 + sin(a) * blade), color: color)
        }
        raster.plot(Int(x), Int(hubY), color)
        if isEvening, still || Int(t * 1.2) % 2 == 0 { raster.plot(Int(x), Int(hubY) - 1, 0xFF4A4A) }
    }

    /// A lattice pylon; returns the tip of its cross-arm for the wires.
    mutating func pylon(x: Double, base: Double, height ph: Double, color: UInt32) -> (x: Double, y: Double) {
        let top = base - ph
        let spread = ph * 0.22
        raster.line(from: (x - spread, base), to: (x, top), color: color)
        raster.line(from: (x + spread, base), to: (x, top), color: color)
        let arm = top + ph * 0.18
        raster.line(from: (x - spread * 1.3, arm), to: (x + spread * 1.3, arm), color: color)
        if ph > 10 {
            raster.line(from: (x - spread * 0.55, top + ph * 0.5), to: (x + spread * 0.55, top + ph * 0.5), color: color)
            raster.line(from: (x - spread * 0.5, top + ph * 0.5), to: (x + spread * 0.75, base), color: color)
        }
        return (x + spread * 1.3, arm)
    }

    mutating func wire(from a: (x: Double, y: Double), to b: (x: Double, y: Double), sag: Double, color: UInt32) {
        let steps = Int(abs(b.x - a.x))
        guard steps > 1 else { return }
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            raster.plot(Int(a.x + (b.x - a.x) * f), Int(a.y + (b.y - a.y) * f + sag * sin(f * .pi)), color)
        }
    }

    /// Curtains of light: rays of varying height over a bright lower edge, fading upward
    /// from mint to lavender.
    mutating func aurora(strength: Double, top: Double, bottom: Double) {
        let drift = still ? 0 : t
        for k in 0..<2 {
            let kd = Double(k)
            for x in 0..<w {
                let fx = Double(x) / Double(w)
                let edge = Y(top + (bottom - top) * (0.55 + 0.25 * kd))
                    + Y(0.08) * sin(fx * 4.6 + kd * 2.3 + drift * 0.04)
                    + Y(0.025) * sin(fx * 12.1 + drift * 0.09 + kd)
                let ray = valueNoise(Double(x) * 0.35 / max(0.6, u) + drift * 0.25, kd * 7, seed: 171 + k)
                let height = Y(0.3) * (0.25 + 0.75 * ray) * (0.7 + 0.3 * sin(fx * 2.2 + kd * 1.7 + drift * 0.03))
                let lower = Int(edge + 1), upper = Int(edge - height)
                guard lower > upper else { continue }
                for y in stride(from: max(0, upper), through: min(h - 1, lower), by: 1) {
                    let d = (edge - Double(y)) / max(1, height)
                    let alpha = d < 0 ? 0.8 : pow(max(0, 1 - d), 1.3) * (0.45 + 0.55 * ray)
                    let color: UInt32 = d < 0.22 ? 0xC4FFE4 : d < 0.55 ? 0x8FE0C4 : 0xBF92D8
                    raster.blendStepped(x, y, color, alpha: alpha * strength * 0.75, steps: 5)
                }
            }
        }
    }

    /// A large sun with prominence loops along its limb.
    mutating func flaringSun(x: Double, y: Double, radius r: Double) {
        raster.glow(cx: x, cy: y, radius: r * 3.4, color: 0xFFE2A8, strength: 0.8)
        for (k, angle) in [-2.4, -0.9, 0.6, 2.2].enumerated() {
            let loopR = r * (0.45 + 0.2 * hash(k, 1, 75))
            let lift = r + loopR * 0.2 + (still ? 0 : sin(t * 0.6 + Double(k)) * 0.4)
            let cx = x + cos(angle) * lift, cy = y + sin(angle) * lift
            for step in 0..<24 {
                let a = angle - .pi / 2 + Double(step) / 23 * .pi
                raster.plot(Int(cx + cos(a) * loopR), Int(cy + sin(a) * loopR), k % 2 == 0 ? 0xFF9A5C : 0xFFC27A)
            }
        }
        raster.fillCircle(cx: x, cy: y, radius: r, color: 0xFFF2CC)
        raster.fillCircle(cx: x - r * 0.25, cy: y - r * 0.2, radius: r * 0.45, color: 0xFFFBEA)
    }

    // MARK: Superstorm

    /// A vast green shelf cloud above diagonal rain and wind-bent trees.
    mutating func superstorm() {
        let horizon = Int(Y(0.77))
        let intensity: Double = [ScenePeriod.dawn: 0.25, .day: 0.6, .dusk: 1, .night: 1][period] ?? 1
        let palette: (top: UInt32, low: UInt32, rim: UInt32, under: UInt32, glow: UInt32, ground: UInt32) = switch period {
        case .dawn: (0x2A3448, 0x6E7E7A, 0xC8C8A8, 0x4A5A5E, 0xF0C89A, 0x1E2A2C)
        case .day: (0x1C3640, 0x3E5E56, 0xB4D0A8, 0x3A5A50, 0xD0E2A0, 0x1E342E)
        case .dusk: (0x0A171B, 0x24443C, 0xA2C8A6, 0x2C4C44, 0xBDD894, 0x1A302C)
        case .night: (0x050C0E, 0x13282A, 0x6A8C78, 0x18302C, 0x5C7A5A, 0x0E1A18)
        }
        let flash = lightningFlash()
        for y in 0..<horizon {
            for x in 0..<w {
                let fx = Double(x) / Double(w)
                // The shelf base rolls slowly; dawn keeps it low on the horizon.
                // Slow motion moves in whole steps, so most cells hold still between frames.
                let roll = still ? 0 : (t * 0.08 * 12).rounded(.down) / 12
                let shelf = Y(0.43 + (1 - intensity) * 0.22)
                    + Y(0.058) * sin(fx * 4.8 + 0.3 + roll)
                    + Y(0.025) * sin(fx * 12.5 + 1.1)
                    - Y(0.048) * fx
                let py = Double(y) + 0.5
                var c: UInt32
                if py < shelf {
                    let depth = shelf - py
                    let tier = Int(depth / Y(0.057)), fraction = (depth / Y(0.057)).truncatingRemainder(dividingBy: 1)
                    c = Raster.mix(palette.top, palette.low, Self.step(min(1, max(0, 1 - depth / Y(0.4)))))
                    c = Raster.mix(c, palette.rim, Self.step(pow(1 - fraction, 3) * max(0.12, 1 - Double(tier) * 0.24) * 0.5))
                    let drift = still ? 0 : (t * 1.5).rounded(.down)
                    c = Raster.mix(c, palette.top, Self.step(fbm((Double(x) + drift) * 0.08 / max(0.6, u), py * 0.22 / max(0.6, u), seed: 81) * 0.28))
                } else {
                    let below = min(1, max(0, (py - shelf) / max(1, Double(horizon) - shelf)))
                    c = Raster.mix(palette.under, palette.glow, Self.step(pow(below, 1.25)))
                    // Rain shafts on the right, falling right to left.
                    let shaft = min(1, max(0, (fx - (1 - intensity * 0.48)) / 0.08))
                    if shaft > 0 {
                        c = Raster.mix(c, Raster.mix(palette.under, 0x4F7266, 0.5), 0.42 * shaft)
                        let s = Double(x) + py * 0.55
                        if (s / (2.3 * max(0.6, u))).truncatingRemainder(dividingBy: 1) < 0.42,
                           hash(Int(s / (2.3 * max(0.6, u))), Int((py - (still ? 0 : t * 13 * u)) / (3.5 * max(0.6, u))), 83) > 0.45 {
                            c = Raster.mix(c, 0xC4DCC4, 0.3 * shaft)
                        }
                    }
                }
                // Lightning lights only its own part of the sky.
                if flash.amount > 0 {
                    let dx = Double(x) - flash.x, dy = py - Y(0.6)
                    let r2 = (dx * dx + dy * dy) / (Y(0.24) * Y(0.24))
                    if r2 < 1 { c = Raster.mix(c, 0xDFFFCC, 0.32 * flash.amount * (1 - r2)) }
                }
                raster[x, y] = c
            }
        }
        if flash.amount > 0.5 {
            raster.glow(cx: flash.x, cy: Y(0.6), radius: Y(0.22), color: 0xDFFFCC, strength: 0.3 * flash.amount, rings: 3)
            bolt(x: flash.x, top: Y(0.42), bottom: Double(horizon), seed: flash.seed)
        }
        if period == .dawn { birds(count: 3, top: 0.18, bottom: 0.4, color: 0x2A3440) }

        // Distant skyline, ground and the trees.
        var x = 0
        var i = 0
        while x < w {
            let bw = n(3 + 4 * hash(i, 1, 85), minimum: 2), bh = n(2 + 6 * hash(i, 2, 85), minimum: 1)
            raster.fillRect(x: x, y: horizon - bh, width: bw, height: bh, color: Raster.mix(palette.ground, palette.glow, 0.08))
            x += bw + (hash(i, 3, 85) > 0.6 ? 1 : 0)
            i += 1
        }
        raster.ditheredGradient([palette.ground, Raster.mix(palette.ground, 0x000000, 0.35)], top: horizon, bottom: h, softness: 0.6)
        let wind = intensity * (still ? 1 : 0.75 + 0.25 * sin(t * 1.9))
        for (k, spec) in [(0.06, 0.26), (0.15, 0.2), (0.26, 0.29), (0.38, 0.18)].enumerated() {
            tree(x: X(spec.0), base: Y(0.93), height: Y(spec.1), crown: Raster.mix(palette.top, palette.under, 0.4),
                 trunk: Raster.mix(palette.top, 0x000000, 0.4), bend: -Y(0.03) * wind * (1 + 0.3 * hash(k, 1, 87)))
        }
        raster.fillRect(x: 0, y: Int(Y(0.93)), width: w, height: h, color: Raster.mix(palette.top, 0x000000, 0.3))
        // Leaves, paper and small debris crossing right to left.
        if intensity > 0.5 {
            for k in 0..<Int(4 + intensity * 4) {
                let span = Double(w) + 20
                let travel = (t * (9 + 5 * hash(k, 1, 89)) * u).truncatingRemainder(dividingBy: span)
                let dx = Double(w) - (still ? hash(k, 2, 89) * span : (hash(k, 2, 89) * span + travel).truncatingRemainder(dividingBy: span))
                let dy = Y(0.5 + 0.35 * hash(k, 3, 89)) + sin(t * 2 + Double(k)) * 1.2
                raster.plot(Int(dx), Int(dy), k % 3 == 0 ? 0xC8B88A : Raster.mix(palette.top, palette.rim, 0.5))
            }
        }
        if intensity >= 1 { rain(intensity: period == .night ? 1 : 0.6, from: Int(Y(0.45)), slant: -0.55) }
        // The farmhouse at the right edge keeps its lamp on.
        let houseX = Int(X(0.86)), houseTop = Int(Y(0.66))
        raster.fillRect(x: houseX, y: houseTop, width: w - houseX, height: h - houseTop, color: 0x081117)
        polygon([(Double(houseX) - 1, Double(houseTop)), (Double(houseX) + X(0.07), Double(houseTop) - Y(0.08)),
                 (Double(w) + 2, Double(houseTop))], color: 0x081117)
        lampWindow(x: houseX + n(3), y: houseTop + n(3))
    }

    /// Two separated lightning cycles at night, one at dusk; posed in still frames.
    func lightningFlash() -> (amount: Double, x: Double, seed: Int) {
        guard period == .dusk || period == .night else { return (0, 0, 0) }
        if still { return (1, X(0.73), 7) }
        let cycles: [(period: Double, offset: Double, x: Double)] = period == .night
            ? [(7.3, 0, 0.73), (11.9, 4.1, 0.58)] : [(8.6, 0, 0.73)]
        for (k, cycle) in cycles.enumerated() {
            let phase = (t + cycle.offset).truncatingRemainder(dividingBy: cycle.period)
            let amount = phase < 0.12 ? 1 : (phase >= 0.25 && phase < 0.33 ? 0.6 : 0)
            if amount > 0 { return (amount, X(cycle.x), Int(t / cycle.period) * 7 + k) }
        }
        return (0, 0, 0)
    }

    mutating func bolt(x startX: Double, top: Double, bottom: Double, seed: Int) {
        var x = startX
        var y = top
        var previous = (x: x, y: y)
        while y < bottom {
            y += max(1, Double(n(1)))
            x += (hash(Int(y), seed, 91) - 0.5) * 2.2 * max(1, u * 0.7)
            raster.line(from: previous, to: (x, y), color: 0xDFFFCC)
            if hash(Int(y), seed, 93) > 0.93 {
                // A short fork.
                let fx = x + (hash(Int(y), seed, 95) - 0.5) * Double(n(6))
                raster.line(from: (x, y), to: (fx, y + Double(n(3))), color: 0xB8DCA8)
            }
            previous = (x, y)
        }
    }

    /// Diagonal rain streaks; negative slant falls right to left.
    mutating func rain(intensity: Double, from top: Int, slant: Double) {
        let count = Int(Double(w * max(1, h - top)) / (intensity >= 1 ? 26 : 48))
        let length = Double(n(2.6, minimum: 2))
        let span = Double(max(1, h - top))
        for i in 0..<count {
            let fall = still ? 0 : t * (18 + 6 * hash(i, 1, 97)) * u
            let y = Double(top) + (hash(i, 2, 97) * span + fall).truncatingRemainder(dividingBy: span)
            let x = hash(i, 3, 97) * Double(w + h) - (y - Double(top)) * slant - Double(h) * 0.5
            raster.line(from: (x, y), to: (x - slant * length, y + length), color: 0xA8C4B8, alpha: 0.4)
        }
    }

    mutating func birds(count: Int, top: Double, bottom: Double, color: UInt32) {
        for i in 0..<count {
            let span = Double(w) + 10
            let x = (hash(i, 1, 99) * span + (still ? 0 : t * (2 + hash(i, 2, 99)) * u)).truncatingRemainder(dividingBy: span) - 5
            let y = Y(top + (bottom - top) * hash(i, 3, 99))
            let flap = still || Int(t * 3 + Double(i)) % 2 == 0
            raster.plot(Int(x), Int(y), color)
            raster.plot(Int(x) - 1, Int(y) - (flap ? 1 : 0), color)
            raster.plot(Int(x) + 1, Int(y) - (flap ? 1 : 0), color)
        }
    }

    // MARK: UAP Invasion

    /// Saucers over a quiet farm, escalating from a scout light to a mothership.
    mutating func uapInvasion() {
        let horizon = Int(Y(0.6))
        var stops = Self.sky(period)
        if period == .dusk { stops = [0x1C1E4A, 0x33295E, 0x5E3470, 0x9C3F6C, 0xE0566A, 0xFF8466] }
        if period == .night { stops = [0x060A20, 0x0A1030, 0x0E163C, 0x121D48, 0x182656, 0x1E3064] }
        sky(stops, to: horizon + n(2))
        switch period {
        case .dawn:
            sun(x: X(0.78), y: Double(horizon), radius: max(1.5, 1.9 * u), core: 0xFFE2A8, glow: 0xFFB27A)
            driftingClouds(count: 3, top: 0.08, bottom: 0.4, size: 12, light: 0xF6B8A0, mid: 0xB27A98, shade: 0x6E5A8A, seed: 101, speed: 0.5)
        case .day:
            sun(x: X(0.86), y: Y(0.14), radius: max(1.2, 1.4 * u), core: 0xFFF8E2, glow: 0xD4EAFA)
            driftingClouds(count: 4, top: 0.04, bottom: 0.35, size: 13, light: 0xFFFFFF, mid: 0xDCE8F4, shade: 0xA9BED6, seed: 102)
        case .dusk:
            sun(x: X(0.8), y: Double(horizon) - Y(0.02), radius: max(2, 2.3 * u), core: 0xFFA86A, glow: 0xF06A60)
            driftingClouds(count: 3, top: 0.12, bottom: 0.4, size: 14, light: 0xF08A80, mid: 0x8A4A72, shade: 0x4E3062, seed: 103, speed: 0.5)
        case .night:
            stars(until: horizon, density: 0.015, seed: 105)
            moonDisc(x: X(0.44), y: Y(0.12), radius: max(1.2, 1.4 * u))
        }

        let land: (mountain: UInt32, field: UInt32, field2: UInt32, near: UInt32, tree: UInt32) = switch period {
        case .dawn: (0x5A5E8A, 0x3C6A4A, 0x2E5A3E, 0x24462E, 0x1C3A2A)
        case .day: (0x6E8AB4, 0x5CA04E, 0x4A8E42, 0x3A7A36, 0x2A5E30)
        case .dusk: (0x3E3462, 0x2C4A3A, 0x22402F, 0x1A3226, 0x14281E)
        case .night: (0x161E3A, 0x10241E, 0x0C1E18, 0x0A1814, 0x08140F)
        }
        let mountains = hills(base: Y(0.6), amplitude: Y(0.07), seed: 107, frequency: 0.7)
        fillBelow(mountains.map { $0 - Y(0.04) }, color: land.mountain)
        let fields = hills(base: Y(0.66), amplitude: Y(0.025), seed: 108, frequency: 0.9)
        fillBelow(fields, color: land.field)
        // Crop rows.
        for y in Int(Y(0.66))..<Int(Y(0.84)) where y % max(2, n(2)) == 0 {
            for x in 0..<w where Double(y) > fields[x] + 1 { raster.plot(x, y, land.field2) }
        }

        // The farm: house, silo and barn.
        let farmBase = Int(Y(0.7))
        let houseX = Int(X(0.14)), houseW = n(7, minimum: 5), houseH = n(4, minimum: 3)
        let wall: UInt32 = period == .day ? 0xEAE4D8 : period == .night ? 0x3A4050 : 0x9A8E98
        polygon([(Double(houseX) - 1, Double(farmBase - houseH)), (Double(houseX) + Double(houseW) / 2, Double(farmBase - houseH - n(3, minimum: 2))),
                 (Double(houseX + houseW) + 1, Double(farmBase - houseH))], color: period == .day ? 0x5A4A50 : 0x2A2430)
        raster.fillRect(x: houseX, y: farmBase - houseH, width: houseW, height: houseH, color: wall)
        lampWindow(x: houseX + n(1.5), y: farmBase - houseH + n(1), size: n(1.2))
        let siloX = Int(X(0.24))
        raster.fillRect(x: siloX, y: farmBase - n(8, minimum: 5), width: n(2.5, minimum: 2), height: n(8, minimum: 5), color: period == .day ? 0xBCBCB4 : 0x4A4E5A)
        raster.fillEllipse(cx: Double(siloX) + Double(n(2.5, minimum: 2)) / 2, cy: Double(farmBase - n(8, minimum: 5)), rx: Double(n(2.5, minimum: 2)) / 2 + 0.3, ry: Double(n(1)), color: period == .day ? 0x9A9A94 : 0x3A3E4A)
        let barnX = Int(X(0.28)), barnW = n(8, minimum: 5), barnH = n(5, minimum: 3)
        let barn: UInt32 = period == .day ? 0xA8443A : period == .night ? 0x3A1E24 : 0x6A2E36
        polygon([(Double(barnX) - 1, Double(farmBase - barnH)), (Double(barnX) + Double(barnW) / 2, Double(farmBase - barnH - n(3, minimum: 2))),
                 (Double(barnX + barnW) + 1, Double(farmBase - barnH))], color: Raster.mix(barn, 0x000000, 0.25))
        raster.fillRect(x: barnX, y: farmBase - barnH, width: barnW, height: barnH, color: barn)
        raster.fillRect(x: barnX + barnW / 2 - n(1), y: farmBase - n(2.5, minimum: 2), width: n(2, minimum: 2), height: n(2.5, minimum: 2), color: Raster.mix(barn, 0xFFFFFF, 0.3))
        for (k, fx) in [0.06, 0.1, 0.4, 0.44, 0.92].enumerated() {
            tree(x: X(fx), base: Double(farmBase) + Double(n(1)), height: Double(n(6 + 3 * hash(k, 1, 109), minimum: 3)), crown: land.tree,
                 trunk: Raster.mix(land.tree, 0x000000, 0.4), light: period == .day ? 0x3A7A3C : nil)
        }

        // Saucers and beams.
        let ground = Y(0.8)
        switch period {
        case .dawn:
            saucer(x: X(0.6), y: Y(0.28), radius: Double(n(1.2)), beam: nil, phase: 0)
        case .day:
            saucer(x: X(0.38), y: Y(0.16), radius: Double(n(1.4)), beam: nil, phase: 1)
            saucer(x: X(0.7), y: Y(0.3), radius: Double(n(4.2, minimum: 3)), beam: ground, phase: 0)
        case .dusk:
            saucer(x: X(0.52), y: Y(0.26), radius: Double(n(3.2, minimum: 2)), beam: ground, phase: 2)
            saucer(x: X(0.74), y: Y(0.22), radius: Double(n(4.6, minimum: 3)), beam: ground, phase: 0)
        case .night:
            groundRings(x: X(0.66), y: ground, radius: X(0.09))
            saucer(x: X(0.5), y: Y(0.3), radius: Double(n(2.6, minimum: 2)), beam: ground, phase: 2)
            saucer(x: X(0.88), y: Y(0.34), radius: Double(n(2.4, minimum: 2)), beam: ground, phase: 3)
            saucer(x: X(0.66), y: Y(0.2), radius: Double(n(7.5, minimum: 4)), beam: ground, phase: 0, mothership: true)
        }

        // Fence and road in the foreground.
        let fenceTop = Int(Y(0.84))
        raster.fillRect(x: 0, y: fenceTop, width: w, height: h - fenceTop, color: land.near)
        let rail: UInt32 = period == .day ? 0x7A5A40 : 0x2A2222
        raster.fillRect(x: 0, y: fenceTop + n(1), width: w, height: 1, color: rail)
        raster.fillRect(x: 0, y: fenceTop + n(3, minimum: 2), width: w, height: 1, color: rail)
        for x in stride(from: n(2), to: w, by: n(6, minimum: 4)) {
            raster.fillRect(x: x, y: fenceTop, width: 1, height: n(5, minimum: 3), color: rail)
        }
        let roadTop = Int(Y(0.93))
        raster.fillRect(x: 0, y: roadTop, width: w, height: h - roadTop, color: period == .day ? 0x4A4A50 : 0x14161C)
        for x in stride(from: 0, to: w, by: n(8, minimum: 5)) where roadTop + n(1) < h {
            raster.fillRect(x: x, y: roadTop + n(1), width: n(3, minimum: 2), height: 1, color: period == .day ? 0xD8C878 : 0x4A4630)
        }
    }

    mutating func saucer(x: Double, y cy: Double, radius r: Double, beam ground: Double?, phase: Double, mothership: Bool = false) {
        let bob = still ? 0 : sin(t * 1.3 + phase) * 0.6
        let y = cy + bob
        if let ground {
            // A pale green cone, shimmering as it scans.
            let topHalf = r * 0.55, bottomHalf = r * (mothership ? 1.9 : 1.4)
            let scan = still ? 0.5 : 0.5 + 0.5 * sin(t * 0.9 + phase)
            for py in Int(y + r * 0.3)..<Int(ground) {
                let f = (Double(py) - y) / max(1, ground - y)
                let half = topHalf + (bottomHalf - topHalf) * f
                for px in Int(x - half)...Int(x + half) {
                    let edge = abs(Double(px) + 0.5 - x) / max(0.5, half)
                    let shimmer = 0.88 + 0.12 * sin(Double(py) * 0.9 - t * 4 + Double(px) * 0.3)
                    let alpha = (0.2 + 0.1 * scan) * shimmer * (1 - f * 0.35) + (edge > 0.8 ? 0.15 : 0)
                    raster.blendStepped(px, py, edge > 0.8 ? 0xC8FFE6 : 0x9CF0C8, alpha: alpha)
                }
            }
            raster.fillEllipse(cx: x, cy: ground, rx: bottomHalf, ry: max(1, bottomHalf * 0.2), color: 0x9CF0C8, alpha: 0.35)
        }
        if mothership { raster.glow(cx: x, cy: y, radius: r * 1.8, color: 0x3A6A70, strength: 0.6) }
        let ry = max(1, r * 0.3)
        raster.fillEllipse(cx: x, cy: y, rx: r, ry: ry, color: isNight ? 0x6A7488 : 0x9AA4B6)
        raster.fillEllipse(cx: x, cy: y - ry * 0.35, rx: r * 0.92, ry: max(0.6, ry * 0.55), color: isNight ? 0x8A94A8 : 0xD0D8E4)
        raster.fillEllipse(cx: x, cy: y - ry * 0.8, rx: max(0.8, r * 0.38), ry: max(0.8, r * 0.26), color: 0x9CF0C8)
        // Rim lights chase around the disc.
        if r >= 2 {
            let count = mothership ? 9 : 5
            for k in 0..<count {
                let f = (Double(k) + 0.5) / Double(count)
                let lx = x - r * 0.85 + f * r * 1.7
                let on = still ? k % 2 == 0 : (Int(t * 4 + phase) + k) % 3 == 0
                raster.plot(Int(lx), Int(y + ry * 0.4), on ? Ink.lamp : 0x5A6478)
            }
        }
    }

    mutating func groundRings(x: Double, y: Double, radius: Double) {
        for k in 0..<3 {
            let grow = still ? Double(k) / 3 : (t / 4 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
            let r = radius * (0.4 + grow * 0.9)
            for step in 0..<Int(r * 6) {
                let a = Double(step) / (r * 6) * 2 * .pi
                raster.blendStepped(Int(x + cos(a) * r), Int(y + sin(a) * r * 0.22), 0x9CF0C8, alpha: 0.8 * (1 - grow))
            }
        }
    }
}
