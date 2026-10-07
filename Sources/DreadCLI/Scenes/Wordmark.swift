import Foundation
import DreadTerminal

/// The DREADCAST wordmark in 5×7 pixel letters. It greets you in the scene above the
/// app's Now tab, then fades so the scene can take over. It sits on a dark plate so it
/// reads over any sky, cloud or skyline.
enum Wordmark {
    static let text = "DREADCAST"
    static let glyphs: [Character: [String]] = [
        "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    ]
    static let height = 7
    /// Letters are five pixels wide with one between them.
    static let width = text.count * 6 - 1
    static let ink: UInt32 = 0xEEF0F5
    static let plate: UInt32 = 0x0B0F1A

    /// How strongly the wordmark shows, `seconds` after the scene first appears: held for
    /// six seconds, then three steps out.
    static func opacity(after seconds: Double) -> Double {
        switch seconds {
        case ..<6: 1
        case ..<7: 0.6
        case ..<8: 0.3
        default: 0
        }
    }

    /// Draws the wordmark with its top-left corner at (x, y), when it fits.
    static func draw(on raster: inout Raster, x: Int = 3, y: Int = 3, opacity: Double = 1) {
        guard opacity > 0, x >= 2, y >= 2, raster.width >= x + width + 2, raster.height >= y + height + 2 else { return }
        var ink = Set<Int>()
        for (index, letter) in text.enumerated() {
            guard let rows = glyphs[letter] else { continue }
            for (row, line) in rows.enumerated() {
                for (column, cell) in line.enumerated() where cell == "#" {
                    ink.insert((y + row) * raster.width + x + index * 6 + column)
                }
            }
        }
        // A plate behind the word with its corners cut, so nothing in the scene touches
        // the letters.
        let left = x - 2, top = y - 2, right = x + width + 1, bottom = y + height + 1
        for py in top...bottom {
            for px in left...right where !((py == top || py == bottom) && (px == left || px == right)) {
                raster.blend(x: px, y: py, color: plate, alpha: opacity * 0.85)
            }
        }
        for p in ink { raster.blend(x: p % raster.width, y: p / raster.width, color: Self.ink, alpha: opacity) }
    }
}
