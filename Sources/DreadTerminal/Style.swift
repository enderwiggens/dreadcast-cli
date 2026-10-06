import Foundation

public struct RGB: Equatable, Hashable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        self.init(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
    }

    public var hex: UInt32 { UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b) }

    public func mixed(with other: RGB, amount t: Double) -> RGB {
        let t = max(0, min(1, t))
        func c(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * t).rounded()) }
        return RGB(c(r, other.r), c(g, other.g), c(b, other.b))
    }
}

/// Dreadcast brand colors (docs/brand/palette.json in the app) and semantic tokens.
public enum Theme {
    public static let midnight = RGB(hex: 0x10192D)
    public static let shelter = RGB(hex: 0x142536)
    public static let porcelain = RGB(hex: 0xEEF0F5)
    public static let mist = RGB(hex: 0xA8BBC3)
    public static let lamp = RGB(hex: 0xFFCC9F)
    public static let boundary = RGB(hex: 0x75899B)
    public static let faint = RGB(hex: 0x6B7F91)

    public static let information = RGB(hex: 0x9DD6F5)
    public static let advisory = RGB(hex: 0xF4D487)
    public static let warning = RGB(hex: 0xFF947D)
    public static let urgent = RGB(hex: 0xF9ADC8)

    public static let mint = RGB(hex: 0xADF2D1)
    public static let lime = RGB(hex: 0xD9EF9B)
    public static let violet = RGB(hex: 0xD8B5FF)
    public static let rain = RGB(hex: 0x63C8B9)

    /// Lightning age bands: newest to oldest.
    public static let lightning: [RGB] = [
        RGB(hex: 0xFFD60A), RGB(hex: 0xFF9F0A), RGB(hex: 0xFF453A), RGB(hex: 0xBF5AF2), RGB(hex: 0x3D9BFF)
    ]

    // Basemap tones.
    public static let water = RGB(hex: 0x070E1A)
    public static let land = RGB(hex: 0x1B2E45)
    public static let coast = RGB(hex: 0x4D6E8C)
    public static let border = RGB(hex: 0x2E4660)
    public static let stateBorder = RGB(hex: 0x24394F)
    public static let ring = RGB(hex: 0x4A6178)
}

public struct TextStyle: Equatable, Sendable {
    public var foreground: RGB?
    public var background: RGB?
    public var bold = false
    public var dim = false
    public var italic = false
    public var underline = false

    public init(foreground: RGB? = nil, background: RGB? = nil, bold: Bool = false,
                dim: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.dim = dim
        self.italic = italic
        self.underline = underline
    }

    public static func fg(_ color: RGB, bold: Bool = false, italic: Bool = false) -> TextStyle {
        TextStyle(foreground: color, bold: bold, italic: italic)
    }

    public static let bold = TextStyle(bold: true)
}

/// Turns styles into SGR escape sequences for the terminal's color depth.
public struct Styler: Sendable {
    public let mode: ColorMode
    public static let reset = "\u{1B}[0m"

    public init(mode: ColorMode) {
        self.mode = mode
    }

    public var isEnabled: Bool { mode != .none }

    public func paint(_ text: String, _ style: TextStyle) -> String {
        guard mode != .none, !text.isEmpty else { return text }
        let codes = sgr(style)
        return codes.isEmpty ? text : codes + text + Self.reset
    }

    public func paint(_ text: String, _ color: RGB, bold: Bool = false, italic: Bool = false) -> String {
        paint(text, TextStyle(foreground: color, bold: bold, italic: italic))
    }

    public func bold(_ text: String) -> String { paint(text, .bold) }

    public func sgr(_ style: TextStyle) -> String {
        guard mode != .none else { return "" }
        var parts: [String] = []
        if style.bold { parts.append("1") }
        if style.dim { parts.append("2") }
        if style.italic { parts.append("3") }
        if style.underline { parts.append("4") }
        if let fg = style.foreground { parts.append(foregroundCode(fg)) }
        if let bg = style.background { parts.append(backgroundCode(bg)) }
        return parts.isEmpty ? "" : "\u{1B}[" + parts.joined(separator: ";") + "m"
    }

    public func foregroundCode(_ c: RGB) -> String {
        switch mode {
        case .truecolor: return "38;2;\(c.r);\(c.g);\(c.b)"
        case .ansi256: return "38;5;\(Self.ansi256(c))"
        case .ansi16:
            let (index, bright) = Self.ansi16(c)
            return bright ? "\(90 + index)" : "\(30 + index)"
        case .none: return ""
        }
    }

    public func backgroundCode(_ c: RGB) -> String {
        switch mode {
        case .truecolor: return "48;2;\(c.r);\(c.g);\(c.b)"
        case .ansi256: return "48;5;\(Self.ansi256(c))"
        case .ansi16:
            let (index, bright) = Self.ansi16(c)
            return bright ? "\(100 + index)" : "\(40 + index)"
        case .none: return ""
        }
    }

    /// Nearest xterm-256 color from the 6×6×6 cube or the grayscale ramp.
    public static func ansi256(_ c: RGB) -> UInt8 {
        let levels: [Int] = [0, 95, 135, 175, 215, 255]
        func nearest(_ v: UInt8) -> Int {
            var best = 0
            for i in 1..<6 where abs(levels[i] - Int(v)) < abs(levels[best] - Int(v)) { best = i }
            return best
        }
        let (ri, gi, bi) = (nearest(c.r), nearest(c.g), nearest(c.b))
        let cube = (levels[ri], levels[gi], levels[bi])
        let average = (Int(c.r) + Int(c.g) + Int(c.b)) / 3
        let grayIndex = max(0, min(23, (average - 8 + 5) / 10))
        let gray = 8 + grayIndex * 10
        func distance(_ a: (Int, Int, Int)) -> Int {
            let dr = a.0 - Int(c.r), dg = a.1 - Int(c.g), db = a.2 - Int(c.b)
            return dr * dr + dg * dg + db * db
        }
        if distance((gray, gray, gray)) < distance(cube) { return UInt8(232 + grayIndex) }
        return UInt8(16 + 36 * ri + 6 * gi + bi)
    }

    /// Nearest of the 16 basic ANSI colors: (index 0–7, bright).
    public static func ansi16(_ c: RGB) -> (Int, Bool) {
        let palette: [(RGB, Int, Bool)] = [
            (RGB(0, 0, 0), 0, false), (RGB(205, 49, 49), 1, false), (RGB(13, 188, 121), 2, false),
            (RGB(229, 229, 16), 3, false), (RGB(36, 114, 200), 4, false), (RGB(188, 63, 188), 5, false),
            (RGB(17, 168, 205), 6, false), (RGB(229, 229, 229), 7, false), (RGB(102, 102, 102), 0, true),
            (RGB(241, 76, 76), 1, true), (RGB(35, 209, 139), 2, true), (RGB(245, 245, 67), 3, true),
            (RGB(59, 142, 234), 4, true), (RGB(214, 112, 214), 5, true), (RGB(41, 184, 219), 6, true),
            (RGB(255, 255, 255), 7, true)
        ]
        var best = palette[0]
        var bestDistance = Int.max
        for entry in palette {
            let dr = Int(entry.0.r) - Int(c.r), dg = Int(entry.0.g) - Int(c.g), db = Int(entry.0.b) - Int(c.b)
            let d = dr * dr + dg * dg + db * db
            if d < bestDistance { bestDistance = d; best = entry }
        }
        return (best.1, best.2)
    }
}
