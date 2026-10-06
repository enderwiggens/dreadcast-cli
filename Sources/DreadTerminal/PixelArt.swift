import Foundation

/// Small deterministic noise for procedural art: the same inputs always give the same picture.
public enum PixelNoise {
    /// A value in [0, 1) for integer coordinates and a seed.
    @inline(__always)
    public static func hash(_ x: Int, _ y: Int, _ seed: Int = 0) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 2_147_483_647))
        h = (h ^ (h >> 33)) &* 0xff51afd7ed558ccd
        h = (h ^ (h >> 33)) &* 0xc4ceb9fe1a85ec53
        h ^= h >> 33
        return Double(h >> 11) / Double(1 << 53)
    }
}

public extension Raster {
    /// Sets one pixel, ignoring coordinates outside the raster.
    @inline(__always)
    mutating func plot(_ x: Int, _ y: Int, _ color: UInt32) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        pixels[y * width + x] = color
    }

    func pixel(_ x: Int, _ y: Int) -> UInt32? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return pixels[y * width + x]
    }

    mutating func fillRect(x: Int, y: Int, width w: Int, height h: Int, color: UInt32, alpha: Double = 1) {
        let x0 = max(0, x), y0 = max(0, y), x1 = min(width, x + w), y1 = min(height, y + h)
        guard x0 < x1, y0 < y1 else { return }
        for py in y0..<y1 {
            for px in x0..<x1 { blend(x: px, y: py, color: color, alpha: alpha) }
        }
    }

    /// A crisp ellipse with no anti-aliasing.
    mutating func fillEllipse(cx: Double, cy: Double, rx: Double, ry: Double, color: UInt32, alpha: Double = 1) {
        guard rx > 0, ry > 0, cx.isFinite, cy.isFinite else { return }
        let minY = max(0, Int(floor(cy - ry))), maxY = min(height - 1, Int(ceil(cy + ry)))
        let minX = max(0, Int(floor(cx - rx))), maxX = min(width - 1, Int(ceil(cx + rx)))
        guard minY <= maxY, minX <= maxX else { return }
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
                if dx * dx + dy * dy <= 1 { blend(x: x, y: y, color: color, alpha: alpha) }
            }
        }
    }

    /// Blends with the alpha rounded to quarter steps, so translucent light keeps
    /// flat pixel-art bands instead of a smooth gradient.
    @inline(__always)
    mutating func blendStepped(_ x: Int, _ y: Int, _ color: UInt32, alpha: Double, steps: Double = 4) {
        let stepped = (min(1, max(0, alpha)) * steps).rounded() / steps
        guard stepped > 0 else { return }
        blend(x: x, y: y, color: color, alpha: stepped)
    }

    /// Light in a few flat rings around a point, the way pixel art draws a glow.
    mutating func glow(cx: Double, cy: Double, radius: Double, color: UInt32, strength: Double = 0.5, rings: Int = 4) {
        guard radius > 0, cx.isFinite, cy.isFinite else { return }
        let minY = max(0, Int(floor(cy - radius))), maxY = min(height - 1, Int(ceil(cy + radius)))
        let minX = max(0, Int(floor(cx - radius))), maxX = min(width - 1, Int(ceil(cx + radius)))
        guard minY <= maxY, minX <= maxX else { return }
        for y in minY...maxY {
            for x in minX...maxX {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let d = (dx * dx + dy * dy).squareRoot() / radius
                guard d < 1 else { continue }
                let level = ceil((1 - d) * Double(rings)) / Double(rings)
                blend(x: x, y: y, color: color, alpha: strength * level * level)
            }
        }
    }
}

/// One frame of half-block cells. Comparing frames lets an animation redraw only the
/// cells that changed, which keeps full-screen scenes light on slow terminals and SSH.
public struct HalfBlockFrame: Sendable, Equatable {
    struct Cell: Equatable, Sendable {
        var top: UInt32
        var bottom: UInt32
        var character: Character?
        /// The right half of a wide character drawn in the cell before.
        var isContinuation = false
        var color: UInt32 = 0
        var background: UInt32 = 0
        var bold = false
        var italic = false
    }

    public let columns: Int
    public let rows: Int
    var cells: [Cell]

    public init(raster: Raster, overlays: [CellOverlay] = []) {
        columns = raster.width
        rows = raster.height / 2
        cells = []
        cells.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                cells.append(Cell(top: raster[column, row * 2], bottom: raster[column, row * 2 + 1]))
            }
        }
        for overlay in overlays where overlay.column >= 0 && overlay.column < columns && overlay.row >= 0 && overlay.row < rows {
            let index = overlay.row * columns + overlay.column
            let cell = cells[index]
            let background = overlay.background ?? RGB(hex: cell.top).mixed(with: RGB(hex: cell.bottom), amount: 0.5)
            cells[index].character = overlay.character
            cells[index].color = overlay.color.hex
            cells[index].background = background.hex
            cells[index].bold = overlay.bold
            cells[index].italic = overlay.italic
            // A wide character covers the next cell too.
            if TextWidth.of(overlay.character) > 1, overlay.column + 1 < columns {
                cells[index + 1].isContinuation = true
            }
        }
    }

    /// Every row as a complete line.
    public func lines(styler: Styler) -> [String] {
        (0..<rows).map { row in
            var state = PaintState()
            var line = ""
            for column in 0..<columns { emit(row * columns + column, into: &line, state: &state, styler: styler) }
            return line + Styler.reset
        }
    }

    /// Escape sequences that turn `previous` into this frame, drawn with its top-left
    /// cell at the 1-based screen `row` and `column`. Redraws everything without a
    /// previous frame of the same size.
    public func update(from previous: HalfBlockFrame?, styler: Styler, row originRow: Int = 1, column originColumn: Int = 1) -> String {
        let old: [Cell]? = previous.flatMap { $0.columns == columns && $0.rows == rows ? $0.cells : nil }
        func unchanged(_ index: Int) -> Bool { old.map { $0[index] == cells[index] } ?? false }
        var out = ""
        var state = PaintState()
        for row in 0..<rows {
            var column = 0
            while column < columns {
                if unchanged(row * columns + column) {
                    column += 1
                    continue
                }
                // Extend the run to the last changed cell, bridging short unchanged gaps
                // that cost less to repaint than a cursor move. `end` is exclusive and
                // always past `column`, so every pass makes progress.
                var end = column + 1
                var probe = column + 1
                var gap = 0
                while probe < columns {
                    if unchanged(row * columns + probe) {
                        gap += 1
                        if gap > 4 { break }
                    } else {
                        gap = 0
                        end = probe + 1
                    }
                    probe += 1
                }
                // Never start a run on the right half of a wide character.
                var start = column
                while start > 0, cells[row * columns + start].isContinuation { start -= 1 }
                out += TerminalControl.moveTo(row: originRow + row, column: originColumn + start)
                for c in start..<end { emit(row * columns + c, into: &out, state: &state, styler: styler) }
                column = end
            }
        }
        return out.isEmpty ? out : out + Styler.reset
    }

    private struct PaintState {
        var foreground: UInt32?
        var background: UInt32?
        var bold = false
        var italic = false
    }

    private func emit(_ index: Int, into line: inout String, state: inout PaintState, styler: Styler) {
        let cell = cells[index]
        if cell.isContinuation { return }
        if let character = cell.character {
            if cell.bold != state.bold {
                line += cell.bold ? "\u{1B}[1m" : "\u{1B}[22m"
                state.bold = cell.bold
            }
            if cell.italic != state.italic {
                line += cell.italic ? "\u{1B}[3m" : "\u{1B}[23m"
                state.italic = cell.italic
            }
            if state.foreground != cell.color { line += "\u{1B}[" + styler.foregroundCode(RGB(hex: cell.color)) + "m"; state.foreground = cell.color }
            if state.background != cell.background { line += "\u{1B}[" + styler.backgroundCode(RGB(hex: cell.background)) + "m"; state.background = cell.background }
            line.append(character)
            return
        }
        if state.bold { line += "\u{1B}[22m"; state.bold = false }
        if state.italic { line += "\u{1B}[23m"; state.italic = false }
        if cell.top == cell.bottom {
            if state.background != cell.top { line += "\u{1B}[" + styler.backgroundCode(RGB(hex: cell.top)) + "m"; state.background = cell.top }
            line += " "
        } else {
            if state.foreground != cell.top { line += "\u{1B}[" + styler.foregroundCode(RGB(hex: cell.top)) + "m"; state.foreground = cell.top }
            if state.background != cell.bottom { line += "\u{1B}[" + styler.backgroundCode(RGB(hex: cell.bottom)) + "m"; state.background = cell.bottom }
            line += "▀"
        }
    }
}
