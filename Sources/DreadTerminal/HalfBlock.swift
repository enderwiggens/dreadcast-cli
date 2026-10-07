import Foundation

/// A character drawn over a cell of a pixel rendering, such as a label or a strike.
public struct CellOverlay: Sendable {
    public let column: Int
    public let row: Int
    public let character: Character
    public let color: RGB
    public let bold: Bool
    public let italic: Bool
    /// When set, replaces the cell background; otherwise the averaged pixels show through.
    public let background: RGB?

    public init(column: Int, row: Int, character: Character, color: RGB, bold: Bool = false, italic: Bool = false, background: RGB? = nil) {
        self.column = column
        self.row = row
        self.character = character
        self.color = color
        self.bold = bold
        self.italic = italic
        self.background = background
    }

    /// One overlay per character of `text`, starting at (column, row).
    public static func text(_ text: String, column: Int, row: Int, color: RGB, bold: Bool = false, italic: Bool = false,
                            background: RGB? = nil) -> [CellOverlay] {
        var result: [CellOverlay] = []
        var c = column
        for character in text {
            result.append(CellOverlay(column: c, row: row, character: character, color: color, bold: bold, italic: italic, background: background))
            c += max(1, TextWidth.of(character))
        }
        return result
    }
}

/// Renders a raster as truecolor or 256-color half blocks: two pixels per cell.
public enum HalfBlockRenderer {
    public static func render(_ raster: Raster, styler: Styler, overlays: [CellOverlay] = []) -> [String] {
        let rows = raster.height / 2
        var overlayMap: [Int: CellOverlay] = [:]
        for overlay in overlays where overlay.column >= 0 && overlay.column < raster.width && overlay.row >= 0 && overlay.row < rows {
            overlayMap[overlay.row * raster.width + overlay.column] = overlay
        }
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0..<rows {
            var line = ""
            line.reserveCapacity(raster.width * 24)
            var currentFG: RGB?
            var currentBG: RGB?
            var currentBold = false
            var skip = 0
            for column in 0..<raster.width {
                if skip > 0 { skip -= 1; continue }
                let top = RGB(hex: raster[column, row * 2])
                let bottom = RGB(hex: raster[column, row * 2 + 1])
                if let overlay = overlayMap[row * raster.width + column] {
                    let bg = overlay.background ?? top.mixed(with: bottom, amount: 0.5)
                    if overlay.bold != currentBold {
                        line += overlay.bold ? "\u{1B}[1m" : "\u{1B}[22m"
                        currentBold = overlay.bold
                    }
                    if currentFG != overlay.color { line += "\u{1B}[" + styler.foregroundCode(overlay.color) + "m"; currentFG = overlay.color }
                    if currentBG != bg { line += "\u{1B}[" + styler.backgroundCode(bg) + "m"; currentBG = bg }
                    line.append(overlay.character)
                    skip = max(0, TextWidth.of(overlay.character) - 1)
                    continue
                }
                if currentBold { line += "\u{1B}[22m"; currentBold = false }
                if top == bottom {
                    if currentBG != top { line += "\u{1B}[" + styler.backgroundCode(top) + "m"; currentBG = top }
                    line += " "
                } else {
                    if currentFG != top { line += "\u{1B}[" + styler.foregroundCode(top) + "m"; currentFG = top }
                    if currentBG != bottom { line += "\u{1B}[" + styler.backgroundCode(bottom) + "m"; currentBG = bottom }
                    line += "▀"
                }
            }
            line += Styler.reset
            lines.append(line)
        }
        return lines
    }
}

/// A canvas of Braille dots: each cell holds a 2×4 grid.
public struct BrailleCanvas: Sendable {
    public let columns: Int
    public let rows: Int
    private var masks: [UInt8]
    private var colors: [UInt32]

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        masks = [UInt8](repeating: 0, count: self.columns * self.rows)
        colors = [UInt32](repeating: 0, count: self.columns * self.rows)
    }

    public var dotWidth: Int { columns * 2 }
    public var dotHeight: Int { rows * 4 }

    private static let bits: [[UInt8]] = [[0x01, 0x02, 0x04, 0x40], [0x08, 0x10, 0x20, 0x80]]

    public mutating func set(dotX: Int, dotY: Int, color: UInt32) {
        guard dotX >= 0, dotY >= 0, dotX < dotWidth, dotY < dotHeight else { return }
        let cell = (dotY / 4) * columns + dotX / 2
        masks[cell] |= Self.bits[dotX % 2][dotY % 4]
        colors[cell] = color
    }

    public func isEmpty(column: Int, row: Int) -> Bool { masks[row * columns + column] == 0 }

    /// Renders the dots over an optional per-cell background raster (columns × rows).
    public func render(styler: Styler, background: Raster? = nil, overlays: [CellOverlay] = []) -> [String] {
        var overlayMap: [Int: CellOverlay] = [:]
        for overlay in overlays where overlay.column >= 0 && overlay.column < columns && overlay.row >= 0 && overlay.row < rows {
            overlayMap[overlay.row * columns + overlay.column] = overlay
        }
        var lines: [String] = []
        for row in 0..<rows {
            var line = ""
            var currentFG: RGB?
            var currentBG: RGB?
            var skip = 0
            for column in 0..<columns {
                if skip > 0 { skip -= 1; continue }
                let index = row * columns + column
                let bg = background.map { RGB(hex: $0[min(column, $0.width - 1), min(row, $0.height - 1)]) }
                if let bg, currentBG != bg, styler.isEnabled { line += "\u{1B}[" + styler.backgroundCode(bg) + "m"; currentBG = bg }
                if let overlay = overlayMap[index] {
                    if styler.isEnabled, currentFG != overlay.color { line += "\u{1B}[" + styler.foregroundCode(overlay.color) + "m"; currentFG = overlay.color }
                    if overlay.bold && styler.isEnabled { line += "\u{1B}[1m" }
                    line.append(overlay.character)
                    if overlay.bold && styler.isEnabled { line += "\u{1B}[22m" }
                    skip = max(0, TextWidth.of(overlay.character) - 1)
                    continue
                }
                let mask = masks[index]
                if mask == 0 {
                    line += " "
                } else {
                    let color = RGB(hex: colors[index])
                    if styler.isEnabled, currentFG != color { line += "\u{1B}[" + styler.foregroundCode(color) + "m"; currentFG = color }
                    line.append(Character(Unicode.Scalar(0x2800 + UInt32(mask))!))
                }
            }
            if styler.isEnabled { line += Styler.reset }
            lines.append(line)
        }
        return lines
    }
}
