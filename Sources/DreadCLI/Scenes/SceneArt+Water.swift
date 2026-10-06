import Foundation
import DreadTerminal

// Deep Trouble and Clear for Now: a harbor with company, and a cove with none.
extension SceneCanvas {
    // MARK: Deep Trouble

    /// A harbor town, a lighthouse and something large in the water.
    mutating func deepTrouble() {
        let sea = Int(Y(0.6))
        var stops = Self.sky(period)
        if period == .night { stops = [0x060B20, 0x091230, 0x0D1A3C, 0x122348, 0x182E56, 0x203A64] }
        sky(stops, to: sea + 1)
        switch period {
        case .dawn:
            sun(x: X(0.62), y: Double(sea), radius: max(1.5, 1.9 * u), core: 0xFFE2A8, glow: 0xFFB27A)
            driftingClouds(count: 3, top: 0.05, bottom: 0.35, size: 12, light: 0xF6BCA4, mid: 0xB0849E, shade: 0x6E6290, seed: 121, speed: 0.5)
        case .day:
            sun(x: X(0.7), y: Y(0.14), radius: max(1.2, 1.4 * u), core: 0xFFF8E2, glow: 0xD4EAFA)
            driftingClouds(count: 4, top: 0.04, bottom: 0.32, size: 12, light: 0xFFFFFF, mid: 0xDCE8F4, shade: 0xA9BED6, seed: 122)
        case .dusk:
            sun(x: X(0.66), y: Double(sea) - Y(0.02), radius: max(2, 2.3 * u), core: 0xFFB06A, glow: 0xF07C5C)
            driftingClouds(count: 3, top: 0.08, bottom: 0.32, size: 12, light: 0xF6A48A, mid: 0x9C5A78, shade: 0x5E3A62, seed: 123, speed: 0.5)
        case .night:
            stars(until: sea - n(2), density: 0.014, seed: 125)
            moonDisc(x: X(0.8), y: Y(0.15), radius: max(1.3, 1.6 * u))
        }

        let tones: (cliff: UInt32, hill: UInt32, water: UInt32, rock: UInt32) = switch period {
        case .dawn: (0x6A5E8E, 0x3E4A5E, 0x2A3A64, 0x1E2234)
        case .day: (0x7E9AB8, 0x3E6E4A, 0x2A66A8, 0x2A3038)
        case .dusk: (0x4A3A66, 0x2A3040, 0x22305A, 0x16182A)
        case .night: (0x18203A, 0x0E1624, 0x0A1430, 0x080C16)
        }
        // Distant cliffs across the bay.
        let cliffs = hills(base: Y(0.56), amplitude: Y(0.03), seed: 127, frequency: 0.6)
        for x in Int(X(0.34))..<Int(X(0.78)) {
            let fade = min(1, min(Double(x) - X(0.34), X(0.78) - Double(x)) / X(0.06))
            let top = Int(cliffs[x] + (1 - fade) * Y(0.04))
            for y in stride(from: max(0, top), through: sea, by: 1) { raster[x, y] = tones.cliff }
        }

        // The town climbing the hill on the left, its church at the top.
        let hillLine: [Double] = (0..<w).map { x in
            let f = Double(x) / X(0.34)
            return f >= 1 ? Double(sea) : Y(0.3) + (Double(sea) - Y(0.3)) * pow(f, 1.8)
        }
        fillBelow(hillLine, color: tones.hill, to: sea + 1)
        let roofs: [UInt32] = [0xC9584A, 0x6B8FB5, 0xD8A05A, 0x8E5E8A]
        let wallDay: [UInt32] = [0xEDE2CC, 0xF2D2B0, 0xE2E8EE, 0xF0E0B8]
        var x = n(1)
        var k = 0
        while Double(x) < X(0.31) {
            let houseW = n(3.5 + 2 * hash(k, 1, 129), minimum: 3), houseH = n(3 + 1.5 * hash(k, 2, 129), minimum: 2)
            let ground = Int(hillLine[min(w - 1, x + houseW / 2)])
            let top = ground - houseH
            let wall: UInt32 = switch period {
            case .day: wallDay[k % wallDay.count]
            case .dawn: Raster.mix(wallDay[k % wallDay.count], 0x6A5A8A, 0.45)
            case .dusk: Raster.mix(wallDay[k % wallDay.count], 0x4A3A60, 0.55)
            case .night: Raster.mix(wallDay[k % wallDay.count], 0x101828, 0.8)
            }
            raster.fillRect(x: x, y: top, width: houseW, height: houseH + n(2), color: wall)
            raster.fillRect(x: x - 1, y: top - 1, width: houseW + 2, height: n(1), color: Raster.mix(roofs[k % roofs.count], 0x000000, isNight ? 0.6 : 0.1))
            if isEvening || period == .dawn, hash(k, 3, 129) < (isNight ? 0.8 : 0.5) {
                raster.plot(x + houseW / 2, top + n(1) + 1, 0xFFD9A0)
                reflection(x: Double(x + houseW / 2), from: sea + 1, to: sea + n(6), width: 0.5, color: 0xFFD9A0, strength: 0.5, seed: k)
            }
            x += houseW + (hash(k, 4, 129) > 0.6 ? 1 : 0)
            k += 1
        }
        let churchX = Int(X(0.1))
        let churchBase = Int(hillLine[churchX]) - n(2)
        raster.fillRect(x: churchX, y: churchBase - n(5, minimum: 3), width: n(2, minimum: 2), height: n(5, minimum: 3), color: period == .day ? 0xE8E2D4 : Raster.mix(0xE8E2D4, 0x101828, 0.75))
        polygon([(Double(churchX) - 0.5, Double(churchBase - n(5, minimum: 3))), (Double(churchX) + Double(n(2, minimum: 2)) / 2, Double(churchBase - n(9, minimum: 5))),
                 (Double(churchX + n(2, minimum: 2)) + 0.5, Double(churchBase - n(5, minimum: 3)))], color: isNight ? 0x1A1E2A : 0x4A3A44)

        // The water, before anything rises out of it.
        water(from: sea + 1, to: h, sky: stops, tint: tones.water, shimmer: isNight ? 0x6A86C0 : 0xCFE2F5)
        switch period {
        case .dawn: reflection(x: X(0.62), from: sea + 1, to: h, width: Double(n(2)), color: 0xFFC890, strength: 0.8)
        case .dusk: reflection(x: X(0.66), from: sea + 1, to: h, width: Double(n(2.5)), color: 0xFFA86A, strength: 0.85)
        case .night: reflection(x: X(0.8), from: sea + 1, to: h, width: Double(n(1.5)), color: 0xDCE2F0, strength: 0.6)
        case .day: break
        }

        // The breakwater and lighthouse on the right.
        let pierTop = sea - n(2)
        raster.fillRect(x: Int(X(0.72)), y: pierTop, width: w, height: n(3, minimum: 2), color: tones.rock)
        let lighthouseX = Int(X(0.83)), towerH = Int(Y(0.24)), towerW = n(2.6, minimum: 2)
        let towerTop = pierTop - towerH
        for y in towerTop..<pierTop {
            let band = ((y - towerTop) / max(1, n(3, minimum: 2))) % 2 == 1
            let white: UInt32 = isNight ? 0x8A92A8 : period == .dusk ? 0xD8C8C8 : 0xF2F2EE
            raster.fillRect(x: lighthouseX, y: y, width: towerW, height: 1, color: band && period == .day ? 0xC9584A : white)
        }
        raster.fillRect(x: lighthouseX - 1, y: towerTop - n(2), width: towerW + 2, height: n(2), color: isNight ? 0x1A1E2A : 0x3A3A44)
        let lightOn = period != .day
        raster.fillRect(x: lighthouseX, y: towerTop - n(2) + 1, width: towerW, height: max(1, n(2) - 1), color: lightOn ? Ink.lampHot : 0x8AA0B0)
        if lightOn { lighthouseBeam(x: Double(lighthouseX) + Double(towerW) / 2, y: Double(towerTop - n(1)), sea: sea) }
        // A harbor house beside the lighthouse keeps its lamp on.
        let houseX = Int(X(0.92)), houseH = n(4, minimum: 3)
        raster.fillRect(x: houseX, y: pierTop - houseH, width: w - houseX, height: houseH, color: isNight ? 0x101622 : 0x3A3440)
        lampWindow(x: houseX + n(1.5), y: pierTop - houseH + n(1))
        // Boats along the town quay.
        for (k, fx) in [0.1, 0.2, 0.27].enumerated() {
            let bx = Int(X(fx)), by = sea + n(1)
            let hull: UInt32 = [0xC9584A, 0xEDE2CC, 0x4A6A9A][k]
            let hullColor = isNight ? Raster.mix(hull, 0x0A1020, 0.7) : hull
            raster.fillRect(x: bx, y: by, width: n(4, minimum: 3), height: max(1, n(1)), color: hullColor)
            raster.fillRect(x: bx + n(1), y: by - n(1), width: n(1.5), height: n(1), color: Raster.mix(hullColor, 0xFFFFFF, 0.3))
        }

        creature(sea: sea, stops: stops)
    }

    mutating func lighthouseBeam(x: Double, y: Double, sea: Int) {
        let angle = still ? 0.5 : t * 0.55
        let facing = cos(angle)
        let direction: Double = facing >= 0 ? -1 : 1
        let strength = 0.15 + 0.4 * abs(facing)
        let length = X(0.3)
        for i in 1..<Int(length) {
            let f = Double(i) / length
            let half = Double(i) * 0.12
            for j in Int(-half)...Int(half) {
                let py = Int(y + Double(j))
                guard py < sea else { continue }
                raster.blendStepped(Int(x + direction * Double(i)), py, 0xFFE6C4, alpha: strength * 0.7 * (1 - f) * (1 - abs(Double(j)) / max(1, half + 1)))
            }
        }
    }

    /// From a few bubbles at dawn to the whole creature by night.
    mutating func creature(sea: Int, stops: [UInt32]) {
        let body: UInt32 = isNight ? 0x1E4E4A : 0x2C6A63
        let light: UInt32 = isNight ? 0x2E6A60 : 0x4F9A88
        let sucker: UInt32 = isNight ? 0x5A9A8A : 0xA8E0CC
        let waterline = Double(sea) + Double(n(1))
        switch period {
        case .dawn:
            for k in 0..<3 {
                let grow = still ? Double(k) / 3 : (t / 3 + Double(k) / 3).truncatingRemainder(dividingBy: 1)
                let r = Double(n(1)) + grow * Double(n(5))
                for step in 0..<Int(r * 6 + 4) {
                    let a = Double(step) / (r * 6 + 4) * 2 * .pi
                    raster.blendStepped(Int(X(0.54) + cos(a) * r), Int(waterline + Double(n(2)) + sin(a) * r * 0.25), 0xC8D8F0, alpha: 0.7 * (1 - grow))
                }
            }
            bubbles(x: X(0.54), sea: sea, count: 4)
        case .day:
            tentacle(baseX: X(0.52), water: waterline, height: Y(0.24), thickness: Double(n(1.8)), sway: 0, body: body, light: light, sucker: sucker)
            tentacle(baseX: X(0.61), water: waterline, height: Y(0.14), thickness: Double(n(1.4)), sway: 2, body: body, light: light, sucker: sucker)
            bubbles(x: X(0.57), sea: sea, count: 3)
        case .dusk, .night:
            let domeX = X(0.56), domeW = X(0.11), domeH = Y(0.13)
            let rise = still ? 0 : sin(t / 7) * Double(n(1)) * 0.6
            let surface = Int(waterline)
            for y in stride(from: max(0, Int(waterline + rise - domeH)), through: surface, by: 1) {
                for x in Int(domeX - domeW)...Int(domeX + domeW) {
                    let dx = (Double(x) + 0.5 - domeX) / domeW, dy = (Double(y) + 0.5 - waterline - rise) / domeH
                    if dx * dx + dy * dy <= 1 { raster.plot(x, y, body) }
                }
            }
            // A dark, broken reflection under the body.
            for y in (surface + 1)..<min(h, surface + Int(domeH * 0.8) + 1) {
                let depth = Double(y - surface) / max(1, domeH * 0.8)
                let half = domeW * (1 - depth * 0.5)
                for x in Int(domeX - half)...Int(domeX + half) where hash(x / 2, y, 137) > 0.25 {
                    raster.blendStepped(x, y, body, alpha: 0.55 * (1 - depth))
                }
            }
            raster.fillEllipse(cx: domeX - domeW * 0.25, cy: waterline - domeH * 0.45 + rise, rx: domeW * 0.45, ry: domeH * 0.3, color: light)
            for k in 0..<6 {
                let sx = domeX + (hash(k, 1, 131) - 0.5) * domeW * 1.4, sy = waterline - domeH * (0.2 + 0.5 * hash(k, 2, 131)) + rise
                raster.plot(Int(sx), Int(sy), Raster.mix(body, 0x000000, 0.3))
            }
            // Eyes, with their reflections.
            let blink = !still && (t.truncatingRemainder(dividingBy: 9) < 0.15)
            for side in [-1.0, 1.0] {
                let ex = domeX + side * domeW * 0.38, ey = waterline - domeH * 0.18 + rise
                raster.glow(cx: ex, cy: ey, radius: Double(n(3)), color: 0xF4D487, strength: isNight ? 0.9 : 0.6)
                if !blink { raster.fillRect(x: Int(ex), y: Int(ey), width: n(1.5), height: max(1, n(1)), color: 0xF4D487) }
                reflection(x: ex, from: Int(waterline) + n(1), to: min(h, Int(waterline) + n(9)), width: 0.6, color: 0xF4D487, strength: 0.6, seed: Int(side) + 140)
            }
            let arms: [(x: Double, height: Double, sway: Double)] = isNight
                ? [(0.38, 0.2, 0), (0.45, 0.13, 1), (0.69, 0.22, 2), (0.76, 0.12, 3)]
                : [(0.42, 0.17, 0), (0.7, 0.2, 2)]
            for arm in arms {
                tentacle(baseX: X(arm.x), water: waterline, height: Y(arm.height), thickness: Double(n(1.5)), sway: arm.sway,
                         body: body, light: light, sucker: sucker)
            }
        }
    }

    /// A curling, swaying arm with suckers along one side.
    mutating func tentacle(baseX: Double, water: Double, height th: Double, thickness: Double, sway: Double,
                           body: UInt32, light: UInt32, sucker: UInt32) {
        let motion = still ? 0.6 : sin(t * 0.7 + sway)
        var points: [(x: Double, y: Double)] = []
        let steps = max(6, Int(th))
        for i in 0...steps {
            let s = Double(i) / Double(steps)
            var x = baseX + sin(s * .pi * 1.1 + sway) * th * 0.18 * s + motion * th * 0.12 * s * s
            var y = water - s * th
            if s > 0.75 {
                // The tip curls over.
                let c = (s - 0.75) / 0.25
                x += sin(c * .pi * 0.9) * th * 0.16 * (sway.truncatingRemainder(dividingBy: 2) < 1 ? 1 : -1)
                y += (1 - cos(c * .pi * 0.9)) * th * 0.12
            }
            points.append((x, y))
        }
        stroke(points, radius: { s in max(0.5, thickness * (1 - 0.72 * s)) }, color: { s in s < 0.15 ? body : (s * 10).truncatingRemainder(dividingBy: 2) < 1 ? body : light })
        for (i, p) in points.enumerated() where i % 2 == 0 && i < points.count - 2 && thickness >= 1.4 {
            raster.plot(Int(p.x + thickness * 0.6), Int(p.y), sucker)
        }
    }

    mutating func bubbles(x: Double, sea: Int, count: Int) {
        for k in 0..<count {
            let f = still ? hash(k, 1, 135) : (t / 2.5 + hash(k, 1, 135)).truncatingRemainder(dividingBy: 1)
            let bx = x + (hash(k, 2, 135) - 0.5) * X(0.04)
            let by = Double(sea) + Double(n(3)) - f * Double(n(4))
            raster.blend(x: Int(bx), y: Int(by), color: 0xC8E0F0, alpha: 1 - f * 0.6)
        }
    }

    // MARK: Clear for Now

    /// A quiet cove. Nothing is happening. That is the joke.
    mutating func clearForNow() {
        let horizon = Int(Y(0.5))
        var stops = Self.sky(period)
        if period == .day { stops = [0x2E6CC4, 0x3A80D2, 0x4E96DC, 0x6AAEE6, 0x8EC6EE, 0xB8DEF4] }
        sky(stops, to: horizon + 1)
        let sunX: Double
        switch period {
        case .dawn:
            sunX = X(0.5)
            sun(x: sunX, y: Double(horizon), radius: max(1.5, 2 * u), core: 0xFFE2A8, glow: 0xFFB27A)
            driftingClouds(count: 3, top: 0.06, bottom: 0.35, size: 13, light: 0xF6BCA4, mid: 0xB0849E, shade: 0x7A6A96, seed: 141, speed: 0.4)
        case .day:
            sunX = X(0.42)
            sun(x: sunX, y: Y(0.16), radius: max(1.3, 1.6 * u), core: 0xFFFCEE, glow: 0xE0F2FC)
            driftingClouds(count: 3, top: 0.05, bottom: 0.3, size: 13, light: 0xFFFFFF, mid: 0xE4EEF8, shade: 0xB4C8DE, seed: 142, speed: 0.6)
        case .dusk:
            sunX = X(0.62)
            sun(x: sunX, y: Double(horizon) - Y(0.01), radius: max(2, 2.4 * u), core: 0xFFB06A, glow: 0xF07C5C)
            driftingClouds(count: 2, top: 0.1, bottom: 0.3, size: 14, light: 0xF6A48A, mid: 0x9C5A78, shade: 0x5E3A62, seed: 143, speed: 0.4)
        case .night:
            sunX = X(0.7)
            stars(until: horizon - n(2), density: 0.016, seed: 145)
            moonDisc(x: sunX, y: Y(0.14), radius: max(1.3, 1.6 * u))
        }

        let tones: (land: UInt32, landFar: UInt32, sea: UInt32, shallow: UInt32, sand: UInt32, sandShade: UInt32, palm: UInt32, trunk: UInt32) = switch period {
        case .dawn: (0x3E4A6A, 0x6A6890, 0x3A4E86, 0x4E6E9A, 0xE8C8A8, 0xC09A88, 0x2A3A3A, 0x4A3A3A)
        case .day: (0x4A7A6A, 0x86A6C0, 0x1E6EB0, 0x3EB6C8, 0xF2DCA8, 0xD8BC88, 0x2E7A3E, 0x7A5A3E)
        case .dusk: (0x3A3456, 0x5A4870, 0x2A3A6A, 0x3A4E7A, 0xD8A88A, 0xA8786E, 0x1E2A2E, 0x3A2A2A)
        case .night: (0x101A28, 0x1A2438, 0x0C1838, 0x14264A, 0x5A6074, 0x3E4458, 0x0C1418, 0x1A1616)
        }
        // Headlands on either side of the bay.
        let left = hills(base: Y(0.47), amplitude: Y(0.03), seed: 147, frequency: 0.5)
        for x in 0..<Int(X(0.26)) {
            let slope = max(0, (X(0.26) - Double(x)) / X(0.26))
            let top = Int(Double(horizon) - (Double(horizon) - left[x]) * slope * 1.6)
            for y in stride(from: max(0, top), through: horizon, by: 1) { raster[x, y] = tones.landFar }
        }
        for x in Int(X(0.7))..<w {
            let slope = max(0, (Double(x) - X(0.7)) / X(0.3))
            let top = Int(Double(horizon) - Y(0.08) * min(1, slope * 2.2) - Y(0.02) * sin(Double(x) * 0.3))
            for y in stride(from: max(0, top), through: horizon, by: 1) { raster[x, y] = tones.landFar }
        }

        // The sea: deep at the horizon, turquoise near the shore.
        let shoreline: [Double] = (0..<w).map { x in
            let f = Double(x) / Double(w)
            return Y(0.74) + Y(0.1) * sin(f * .pi * 0.9 + 0.2) - Y(0.06) * f
        }
        for y in (horizon + 1)..<h {
            let depth = Double(y - horizon) / Y(0.3)
            let base = Raster.mix(tones.sea, tones.shallow, min(1, depth))
            for x in 0..<w where Double(y) < shoreline[x] + 2 { raster[x, y] = base }
        }
        for y in (horizon + 1)..<h {
            for x in 0..<w where Double(y) < shoreline[x] {
                let shifted = Int(floor((Double(x) + t * 0.8 * u) / Double(max(2, n(3)))))
                if hash(shifted, y, 149) > 0.88 { raster.plot(x, y, Raster.mix(raster[x, y], 0xFFFFFF, isNight ? 0.15 : 0.35)) }
            }
        }
        let glint: UInt32 = switch period {
        case .dawn: 0xFFD0A0
        case .day: 0xFFFFFF
        case .dusk: 0xFFA86A
        case .night: 0xDCE2F0
        }
        reflection(x: sunX, from: horizon + 1, to: Int(Y(0.78)), width: Double(n(2)), color: glint, strength: period == .day ? 0.5 : 0.8)

        // Sand, with foam where the waves arrive.
        for x in 0..<w {
            let top = Int(shoreline[x].rounded())
            for y in max(0, top)..<h {
                let shade = hash(x, y, 151) > 0.96 || Double(y) > Y(0.9) + sin(Double(x) * 0.1) * Y(0.02)
                raster[x, y] = shade ? tones.sandShade : tones.sand
            }
            let reach = still ? 0.5 : 0.5 + 0.5 * sin(t * 0.8 + Double(x) * 0.04)
            let foamY = Int((shoreline[x] - 1 + reach * Double(n(1.5))).rounded())
            raster.plot(x, foamY, isNight ? 0x8A96B0 : 0xF4FAFF)
            if hash(x, 3, 153) > 0.5 { raster.plot(x, foamY - 1, isNight ? 0x4A5A7A : 0xCDEAF2) }
        }

        // A bench and boardwalk on the left; a cabin keeps its lamp on.
        let walkY = Int(Y(0.86))
        raster.fillRect(x: 0, y: walkY, width: Int(X(0.16)), height: n(1.5), color: Raster.mix(tones.trunk, 0x000000, 0.1))
        let benchX = Int(X(0.1))
        raster.fillRect(x: benchX, y: walkY - n(2, minimum: 2), width: n(5, minimum: 3), height: 1, color: tones.trunk)
        raster.fillRect(x: benchX, y: walkY - n(3.5, minimum: 3), width: n(5, minimum: 3), height: 1, color: tones.trunk)
        raster.plot(benchX, walkY - 1, tones.trunk)
        raster.plot(benchX + n(5, minimum: 3) - 1, walkY - 1, tones.trunk)
        let cabinX = Int(X(0.02)), cabinTop = Int(Y(0.7))
        raster.fillRect(x: cabinX, y: cabinTop, width: n(6, minimum: 4), height: walkY - cabinTop, color: Raster.mix(tones.land, 0x000000, 0.35))
        polygon([(Double(cabinX) - 1, Double(cabinTop)), (Double(cabinX) + Double(n(3, minimum: 2)), Double(cabinTop) - Double(n(2.5, minimum: 2))),
                 (Double(cabinX + n(6, minimum: 4)) + 1, Double(cabinTop))], color: Raster.mix(tones.land, 0x000000, 0.5))
        lampWindow(x: cabinX + n(2), y: cabinTop + n(1.5), size: n(1.3))

        // Palms on the right, fronds moving a little in the breeze.
        for (k, spec) in [(0.84, 0.36, -0.06), (0.9, 0.28, -0.03), (0.78, 0.22, -0.08)].enumerated() {
            palm(x: X(spec.0), base: shoreline[min(w - 1, Int(X(spec.0)))] + Y(0.06), height: Y(spec.1), lean: X(spec.2), tones: (tones.palm, tones.trunk), phase: Double(k))
        }
        if period == .day || period == .dawn { birds(count: 2, top: 0.18, bottom: 0.32, color: period == .day ? 0x3A4A5A : 0x3A3050) }
    }

    mutating func palm(x: Double, base: Double, height ph: Double, lean: Double, tones: (frond: UInt32, trunk: UInt32), phase: Double) {
        var points: [(x: Double, y: Double)] = []
        for i in 0...12 {
            let s = Double(i) / 12
            points.append((x + lean * s * s, base - ph * s))
        }
        let scale = u
        stroke(points, radius: { s in max(0.5, 0.9 * scale * (1 - 0.4 * s)) },
               color: { s in Int(s * 14) % 2 == 0 ? tones.trunk : Raster.mix(tones.trunk, 0xFFFFFF, 0.12) })
        let top = points.last!
        let sway = still ? 0 : sin(t * 0.9 + phase) * 0.08
        let light = Raster.mix(tones.frond, 0xFFFFFF, 0.18)
        for k in 0..<6 {
            // Fronds fan out from the crown and droop toward their tips.
            let side: Double = k < 3 ? -1 : 1
            let spread = [0.25, 0.75, 1.2][k % 3]
            let length = ph * (0.5 + 0.12 * hash(k, Int(phase), 155))
            var previous = (x: top.x, y: top.y)
            let steps = max(4, Int(length))
            for i in 1...steps {
                let s = Double(i) / Double(steps)
                let angle = -.pi / 2 + side * (spread + s * 0.9) + sway
                let point = (x: previous.x + cos(angle) * length / Double(steps), y: previous.y + sin(angle) * length / Double(steps) + s * 0.25)
                raster.line(from: previous, to: point, color: tones.frond)
                // Leaflets hang below the rib.
                if i % 2 == 0, s < 0.92 {
                    let leaf = max(1, (1 - s) * Double(n(2.2)))
                    raster.line(from: point, to: (point.x + side * 0.4, point.y + leaf), color: i % 4 == 0 ? light : tones.frond)
                }
                previous = point
            }
        }
        raster.fillCircle(cx: top.x, cy: top.y + 1, radius: max(0.8, 0.7 * u), color: Raster.mix(tones.trunk, 0x000000, 0.2))
    }
}

extension SceneCanvas {
    /// Water limited to a range of columns, used to settle the surface around the creature.
    mutating func water(from top: Int, to bottom: Int, sky: [UInt32], tint: UInt32, shimmer: UInt32, seed: Int, columns: ClosedRange<Int>) {
        guard bottom > top else { return }
        let lower = max(0, columns.lowerBound), upper = min(w - 1, columns.upperBound)
        guard lower <= upper else { return }
        for y in max(0, top)..<min(h, bottom) {
            let depth = Double(y - top) / Double(max(1, bottom - top))
            let skyIndex = min(sky.count - 1, max(0, sky.count - 1 - Int(depth * Double(sky.count))))
            let base = Raster.mix(sky[skyIndex], tint, 0.45 + 0.35 * depth)
            for x in lower...upper {
                raster[x, y] = base
                let shifted = Int(floor((Double(x) + t * (0.6 + depth * 1.8) * u) / Double(max(2, n(3)))))
                if hash(shifted, y, seed) > 0.86 - depth * 0.08 { raster[x, y] = Raster.mix(base, shimmer, 0.55) }
            }
        }
    }
}
