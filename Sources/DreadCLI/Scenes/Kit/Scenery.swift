import Foundation
import DreadTerminal

/// Scenery shared by the terminal scenes: skylines, ridges, water and reflections,
/// all at one pixel scale with flat color.
extension Stage {
    struct Building {
        let x: Int
        let width: Int
        let height: Int
    }

    /// A row of buildings with windows on a two-pixel grid; a few switch on and off on
    /// long, independent loops.
    @discardableResult
    mutating func buildings(base: Int, seed: Int, widths: ClosedRange<Int>, heights: ClosedRange<Int>,
                            body: UInt32, lit: Double, windows: [UInt32]) -> [Building] {
        var result: [Building] = []
        var x = -2
        var i = 0
        while x < w {
            let width = widths.lowerBound + Int(hash(i, 1, seed) * Double(widths.count))
            let height = heights.lowerBound + Int(pow(hash(i, 2, seed), 1.3) * Double(heights.count))
            let top = base - height
            raster.fillRect(x: x, y: top, width: width, height: height + 1, color: body)
            // A setback or a water tank on some roofs.
            let roof = Int(hash(i, 3, seed) * 5)
            if roof == 0, width >= 6 { raster.fillRect(x: x + 2, y: top - 2, width: width - 4, height: 2, color: body) }
            if roof == 1, width >= 5 {
                raster.fillRect(x: x + 1, y: top - 2, width: 2, height: 1, color: body)
                raster.plot(x + 1, top - 1, body)
                raster.plot(x + 2, top - 1, body)
            }
            if !windows.isEmpty {
                var wy = top + 1
                while wy < base - 1 {
                    var wx = x + 1
                    while wx < x + width - 1 {
                        var on = hash(wx, wy, seed) < lit
                        if hash(wx, wy, seed + 9) < 0.03 { on = on != (tick(5 + 7 * hash(wx, wy, seed + 10), frames: 2) == 1) }
                        if on { raster.plot(wx, wy, windows[Int(hash(wx, wy, seed + 1) * Double(windows.count)) % windows.count]) }
                        wx += 2
                    }
                    wy += 2
                }
            }
            result.append(Building(x: x, width: width, height: height))
            x += width + (hash(i, 4, seed) < 0.25 ? 1 : 0)
            i += 1
        }
        return result
    }

    /// The top of a smooth ridge at each column: `height` pixels at most above `base`.
    func ridgeLine(base: Int, height: Int, seed: Int, wavelength: Double = 37) -> [Int] {
        let a = hash(1, seed, 3) * 6, b = hash(2, seed, 3) * 6
        return (0..<w).map { x in
            let f = Double(x) / wavelength
            let lift = 0.55 + 0.3 * sin(f * 1.7 + a) + 0.15 * sin(f * 4.3 + b)
            return base - Int((Double(height) * max(0, lift)).rounded())
        }
    }

    mutating func fill(below line: [Int], to bottom: Int, color: UInt32) {
        for x in 0..<min(w, line.count) {
            for y in max(0, line[x])..<min(h, bottom) { raster[x, y] = color }
        }
    }

    /// Water in flat bands that darken with depth, with short highlight dashes that
    /// change in four slow phases.
    mutating func water(top: Int, bottom: Int, colors: [UInt32], highlight: UInt32, seed: Int, density: Double = 0.07) {
        guard bottom > top, !colors.isEmpty else { return }
        bands(colors, top: top, bottom: bottom)
        let phase = tick(0.9, frames: 4)
        for y in top..<min(h, bottom) {
            let depth = Double(y - top) / Double(max(1, bottom - top))
            var x = 0
            while x < w {
                let length = 2 + Int(hash(x / 4, y, seed + phase) * 3)
                if hash(x / 4, y, seed + 7 + phase) < density * (0.6 + depth) {
                    for dx in 0..<length { raster.plot(x + dx, y, highlight) }
                }
                x += 4
            }
        }
    }

    /// A broken column of light on water under the sun, the moon or a lit window.
    mutating func reflection(x center: Int, top: Int, bottom: Int, color: UInt32, width: Int = 2, seed: Int = 61) {
        guard bottom > top else { return }
        let phase = tick(0.6, frames: 3)
        for y in top..<min(h, bottom) {
            let depth = Double(y - top) / Double(max(1, bottom - top))
            let half = Int((Double(width) * (0.6 + depth)).rounded())
            guard hash(y, phase, seed) < 0.85 - depth * 0.35 else { continue }
            let shift = Int(hash(y, phase, seed + 1) * 3) - 1
            for x in (center - half + shift)...(center + half + shift) where hash(x, y, seed + phase) < 0.7 {
                raster.plot(x, y, color)
            }
        }
    }

    /// Birds crossing slowly, wings up and down.
    mutating func birds(_ count: Int, top: Int, bottom: Int, color: UInt32, seed: Int = 71) {
        guard bottom > top else { return }
        for i in 0..<count {
            let span = w + 10
            let x = (Int(hash(i, 1, seed) * Double(span)) + Int(t / (1.2 + hash(i, 2, seed)))) % span - 5
            let y = top + Int(hash(i, 3, seed) * Double(bottom - top))
            let up = tick(0.5, frames: 2, offset: Double(i) * 0.3) == 0
            raster.plot(x, y, color)
            raster.plot(x - 1, y - (up ? 1 : 0), color)
            raster.plot(x + 1, y - (up ? 1 : 0), color)
        }
    }

    /// A round tree in two tones with a trunk.
    static let tree = Sprite([
        "..ccc..",
        ".cCccc.",
        "cCcccCc",
        "ccccccc",
        ".ccccc.",
        "...k...",
        "...k...",
    ])

    static let smallTree = Sprite([
        ".ccc.",
        "cCccc",
        ".ccc.",
        "..k..",
    ])
}
