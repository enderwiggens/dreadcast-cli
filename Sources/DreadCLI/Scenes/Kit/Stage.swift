import Foundation
import DreadcastKit
import DreadTerminal

/// Where a scene is shown. Each scene composes all three on purpose rather than
/// cropping one picture into another shape.
public enum SceneLayout: String, Sendable, CaseIterable {
    /// The whole terminal, any aspect.
    case window
    /// An inline 3:1 still.
    case panorama
    /// The short banner over `dread`: the horizon band only.
    case strip
}

/// A small piece of hand-drawn pixel art: rows of palette keys, `.` for clear.
struct Sprite {
    let width: Int
    let height: Int
    private let keys: [Character?]

    init(_ rows: [String]) {
        height = rows.count
        width = rows.map(\.count).max() ?? 0
        var keys: [Character?] = []
        for row in rows {
            let chars = Array(row)
            for x in 0..<width {
                let c = x < chars.count ? chars[x] : "."
                keys.append(c == "." || c == " " ? nil : c)
            }
        }
        self.keys = keys
    }

    func key(_ x: Int, _ y: Int) -> Character? { keys[y * width + x] }

    /// Draws with the top-left corner at (x, y). Keys missing from the palette are skipped.
    func draw(on raster: inout Raster, x: Int, y: Int, palette: [Character: UInt32], flipped: Bool = false) {
        for row in 0..<height {
            for column in 0..<width {
                guard let key = keys[row * width + column], let color = palette[key] else { continue }
                raster.plot(x + (flipped ? width - 1 - column : column), y + row, color)
            }
        }
    }
}

/// The canvas a terminal-native scene draws on, at one fixed pixel scale.
/// Larger terminals show more sky and ground; very large ones double every pixel.
struct Stage {
    var raster: Raster
    let layout: SceneLayout
    let period: ScenePeriod
    let t: Double
    let still: Bool
    let moon: LunarPhase
    var w: Int { raster.width }
    var h: Int { raster.height }

    init(width: Int, height: Int, layout: SceneLayout, period: ScenePeriod, time: Double, still: Bool, moon: LunarPhase) {
        raster = Raster(width: width, height: height)
        self.layout = layout
        self.period = period
        t = still ? 0 : time
        self.still = still
        self.moon = moon
    }

    /// Whole-number scale for a terminal canvas: art stays crisp and proportions hold.
    static func scale(width: Int, height: Int) -> Int {
        height >= 150 || width >= 360 ? 2 : 1
    }

    var isNight: Bool { period == .night }
    var isEvening: Bool { period == .dusk || period == .night }

    func hash(_ x: Int, _ y: Int, _ seed: Int = 0) -> Double { PixelNoise.hash(x, y, seed) }

    /// A frame counter for a loop: advances every `seconds` and wraps after `frames`.
    func tick(_ seconds: Double, frames: Int, offset: Double = 0) -> Int {
        guard frames > 0 else { return 0 }
        return (Int(((t + offset) / seconds).rounded(.down)) % frames + frames) % frames
    }

    /// A slow back-and-forth in whole pixels.
    func bob(_ seconds: Double, amplitude: Int, offset: Double = 0) -> Int {
        guard !still, amplitude > 0 else { return 0 }
        return Int((sin((t / seconds + offset) * 2 * .pi) * Double(amplitude)).rounded())
    }

    // MARK: Sky

    /// Flat color bands from `top` to `bottom`, each seam softened by a single checkered row.
    mutating func bands(_ colors: [UInt32], top: Int = 0, bottom: Int) {
        guard bottom > top, !colors.isEmpty else { return }
        let span = Double(bottom - top) / Double(colors.count)
        for y in max(0, top)..<min(h, bottom) {
            let position = Double(y - top) / span
            let index = min(colors.count - 1, Int(position))
            let seam = index + 1 < colors.count && position - Double(index) >= 1 - 1 / span
            for x in 0..<w {
                raster[x, y] = seam && (x + 2 * y) % 4 == 0 ? colors[index + 1] : colors[index]
            }
        }
    }

    /// Sparse stars, a few twinkling on slow independent loops.
    mutating func stars(above bottom: Int, density: Double = 0.012, seed: Int = 5) {
        for y in 0..<max(0, min(h, bottom)) {
            let fade = 1 - Double(y) / Double(max(1, bottom))
            for x in 0..<w where hash(x, y, seed) < density * fade {
                let bright = hash(x, y, seed + 1)
                var color: UInt32 = bright > 0.7 ? Ink.porcelain : 0x8A9AC0
                if bright > 0.85, tick(0.5, frames: 9, offset: bright * 40) == 0 { color = 0x4A5A80 }
                raster.plot(x, y, color)
            }
        }
    }

    /// A flat disc with stepped rings of light around it.
    mutating func sun(x: Int, y: Int, radius: Int, core: UInt32, glow: UInt32) {
        raster.glow(cx: Double(x) + 0.5, cy: Double(y) + 0.5, radius: Double(radius) * 3.2, color: glow, strength: 0.5, rings: 3)
        raster.fillCircle(cx: Double(x) + 0.5, cy: Double(y) + 0.5, radius: Double(radius) + 0.3, color: core)
    }

    /// Tonight's moon in its real phase, lit from the right while waxing.
    mutating func moonDisc(x: Int, y: Int, radius: Int) {
        let r = Double(radius) + 0.3
        let cx = Double(x) + 0.5, cy = Double(y) + 0.5
        raster.glow(cx: cx, cy: cy, radius: r * 2.6, color: 0x8FA3CC, strength: 0.12 + 0.2 * moon.illumination, rings: 2)
        for py in (y - radius - 1)...(y + radius + 1) {
            for px in (x - radius - 1)...(x + radius + 1) {
                let dx = Double(px) + 0.5 - cx, dy = Double(py) + 0.5 - cy
                guard dx * dx + dy * dy <= r * r else { continue }
                let half = max(0, r * r - dy * dy).squareRoot()
                let edge = half * (1 - 2 * moon.illumination)
                let lit = moon.isWaxing ? dx >= edge : dx <= -edge
                if lit {
                    raster.plot(px, py, radius >= 3 && hash(px, py, 41) < 0.2 ? 0xCFCBC0 : 0xF2EFE2)
                } else {
                    raster.blend(x: px, y: py, color: 0x2A3452, alpha: 0.5)
                }
            }
        }
    }

    /// One of three hand-drawn cloud shapes in three tones, drifting a pixel at a time.
    mutating func cloud(_ shape: Int, x: Int, y: Int, light: UInt32, mid: UInt32, shade: UInt32) {
        let sprite = Stage.clouds[shape % Stage.clouds.count]
        sprite.draw(on: &raster, x: x, y: y, palette: ["l": light, "m": mid, "s": shade])
    }

    mutating func driftingClouds(_ count: Int, top: Int, bottom: Int, light: UInt32, mid: UInt32, shade: UInt32, seed: Int) {
        guard bottom > top else { return }
        for i in 0..<count {
            let span = w + 40
            let step = 2.5 + 2 * hash(i, 1, seed)          // seconds per pixel
            let start = Int(hash(i, 2, seed) * Double(span))
            let x = (start + Int(t / step)) % span - 20
            let y = top + Int(hash(i, 3, seed) * Double(bottom - top))
            cloud(i + seed, x: x, y: y, light: light, mid: mid, shade: shade)
        }
    }

    static let clouds: [Sprite] = [
        Sprite([
            "......llll.......",
            "....llmmmmll.....",
            "..llmmmmmmmmll...",
            ".lmmmmmmmmmmmmll.",
            "ssssssssssssssss.",
        ]),
        Sprite([
            ".....lll...llll......",
            "...llmmmllmmmmmll....",
            ".llmmmmmmmmmmmmmmll..",
            "sssssssssssssssssssss",
        ]),
        Sprite([
            "...llll...",
            ".llmmmmll.",
            "ssssssssss",
        ]),
    ]
}
