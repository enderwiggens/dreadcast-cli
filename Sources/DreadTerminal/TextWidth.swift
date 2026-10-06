import Foundation

public enum Alignment: Sendable { case left, right, center }

/// Display widths in terminal cells: emoji and East Asian wide characters take two.
public enum TextWidth {
    public static func of(_ text: String) -> Int {
        let plain = text.contains("\u{1B}") ? strippingANSI(text) : text
        return plain.reduce(0) { $0 + of($1) }
    }

    public static func of(_ character: Character) -> Int {
        let scalars = character.unicodeScalars
        guard let first = scalars.first else { return 0 }
        if first.value < 0x20 || (0x7F..<0xA0).contains(first.value) { return 0 }
        if scalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
        if first.properties.isEmojiPresentation { return 2 }
        if scalars.count > 1, scalars.contains(where: { $0.value == 0x200D }), first.properties.isEmoji { return 2 }
        switch first.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        return isWide(first.value) ? 2 : 1
    }

    private static func isWide(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return true
        default:
            return false
        }
    }

    static func skipEscape(_ scalars: String.UnicodeScalarView, from start: String.UnicodeScalarView.Index) -> String.UnicodeScalarView.Index {
        var i = scalars.index(after: start)
        guard i < scalars.endIndex else { return i }
        let kind = scalars[i]
        i = scalars.index(after: i)
        switch kind {
        case "[":
            // CSI: parameters then a final byte in 0x40–0x7E.
            while i < scalars.endIndex {
                let v = scalars[i].value
                i = scalars.index(after: i)
                if (0x40...0x7E).contains(v) { break }
            }
        case "]", "_", "P":
            // OSC / APC / DCS: until BEL or ESC \.
            while i < scalars.endIndex {
                let s = scalars[i]
                if s == "\u{07}" { return scalars.index(after: i) }
                if s == "\u{1B}" {
                    let next = scalars.index(after: i)
                    if next < scalars.endIndex, scalars[next] == "\\" { return scalars.index(after: next) }
                }
                i = scalars.index(after: i)
            }
        default:
            break
        }
        return i
    }

    /// Removes ANSI escape sequences.
    public static func strippingANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        let scalars = text.unicodeScalars
        var result = String.UnicodeScalarView()
        var i = scalars.startIndex
        while i < scalars.endIndex {
            if scalars[i] == "\u{1B}" {
                i = skipEscape(scalars, from: i)
            } else {
                result.append(scalars[i])
                i = scalars.index(after: i)
            }
        }
        return String(result)
    }

    /// Pads styled or plain text to `width` cells.
    public static func pad(_ text: String, to width: Int, align: Alignment = .left) -> String {
        let current = of(text)
        guard current < width else { return text }
        let space = width - current
        switch align {
        case .left: return text + String(repeating: " ", count: space)
        case .right: return String(repeating: " ", count: space) + text
        case .center:
            let left = space / 2
            return String(repeating: " ", count: left) + text + String(repeating: " ", count: space - left)
        }
    }

    /// Truncates plain text to `width` cells, adding an ellipsis when shortened.
    public static func truncate(_ text: String, to width: Int, ellipsis: String = "…") -> String {
        guard of(text) > width else { return text }
        guard width > 0 else { return "" }
        var result = ""
        var used = 0
        let limit = width - of(ellipsis)
        for character in text {
            let w = of(character)
            if used + w > limit { break }
            result.append(character)
            used += w
        }
        return result + ellipsis
    }

    /// Word-wraps plain text to `width` cells.
    public static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 4 else { return [text] }
        var lines: [String] = []
        for paragraph in text.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.split(separator: " ", omittingEmptySubsequences: true) {
                let candidate = line.isEmpty ? String(word) : line + " " + word
                if of(candidate) <= width {
                    line = candidate
                } else {
                    if !line.isEmpty { lines.append(line) }
                    line = of(String(word)) > width ? truncate(String(word), to: width) : String(word)
                }
            }
            lines.append(line)
        }
        return lines
    }

    /// Joins left and right parts with spaces so the line fills `width`.
    public static func spread(_ left: String, _ right: String, width: Int) -> String {
        let gap = max(1, width - of(left) - of(right))
        return left + String(repeating: " ", count: gap) + right
    }
}
