import Foundation
import Testing
@testable import DreadTerminal
import DreadcastKit

@Suite("Text width")
struct TextWidthTests {
    @Test func countsTerminalCells() {
        #expect(TextWidth.of("dread") == 5)
        #expect(TextWidth.of("⛈️") == 2)
        #expect(TextWidth.of("🌧️ 71°") == 6)
        #expect(TextWidth.of("東京") == 4)
        #expect(TextWidth.of("é") == 1)
        #expect(TextWidth.of("e\u{301}") == 1)
    }

    @Test func ignoresEscapeSequences() {
        let styled = "\u{1B}[1;38;2;255;204;159mdread\u{1B}[0m"
        #expect(TextWidth.of(styled) == 5)
        #expect(TextWidth.strippingANSI(styled) == "dread")
        let kitty = "\u{1B}_Ga=T,f=100;AAAA\u{1B}\\x"
        #expect(TextWidth.strippingANSI(kitty) == "x")
    }

    @Test func padsTruncatesAndWraps() {
        #expect(TextWidth.pad("ab", to: 4) == "ab  ")
        #expect(TextWidth.pad("ab", to: 4, align: .right) == "  ab")
        #expect(TextWidth.truncate("thunderstorm", to: 6) == "thund…")
        #expect(TextWidth.wrap("one two three four", width: 9) == ["one two", "three", "four"])
        #expect(TextWidth.spread("a", "b", width: 5) == "a   b")
    }
}

@Suite("Rendering")
struct RenderingTests {
    @Test func halfBlocksPackTwoPixelsPerCell() {
        var raster = Raster(width: 2, height: 2, fill: 0x000000)
        raster[0, 0] = 0xFF0000
        let lines = HalfBlockRenderer.render(raster, styler: Styler(mode: .truecolor))
        #expect(lines.count == 1)
        #expect(lines[0].contains("▀"))
        #expect(lines[0].contains("38;2;255;0;0"))
        #expect(TextWidth.of(lines[0]) == 2)
    }

    @Test func overlaysReplaceCells() {
        let raster = Raster(width: 4, height: 2, fill: 0x101010)
        let lines = HalfBlockRenderer.render(raster, styler: Styler(mode: .truecolor),
                                             overlays: CellOverlay.text("hi", column: 1, row: 0, color: Theme.lamp))
        #expect(TextWidth.strippingANSI(lines[0]) == " hi ")
    }

    @Test func brailleDots() {
        var canvas = BrailleCanvas(columns: 1, rows: 1)
        canvas.set(dotX: 0, dotY: 0, color: 0xFFFFFF)
        canvas.set(dotX: 1, dotY: 3, color: 0xFFFFFF)
        let line = TextWidth.strippingANSI(canvas.render(styler: Styler(mode: .none))[0])
        #expect(line == "\u{2881}")
    }

    @Test func polygonFillAndCircle() {
        var raster = Raster(width: 10, height: 10, fill: 0)
        raster.fillPolygons([[(1, 1), (9, 1), (9, 9), (1, 9)]], color: 0xFFFFFF)
        #expect(raster[5, 5] == 0xFFFFFF)
        #expect(raster[0, 0] == 0)
        raster.fillCircle(cx: 500, cy: 500, radius: 3, color: 0x123456) // far outside: must not trap
        #expect(raster[0, 0] == 0)
    }

    @Test func ansi256Mapping() {
        #expect(Styler.ansi256(RGB(255, 0, 0)) == 196)
        #expect(Styler.ansi256(RGB(0, 0, 0)) == 16)
        #expect(Styler.ansi256(RGB(128, 128, 128)) >= 232)
    }

    @Test func noColorModeLeavesTextAlone() {
        let styler = Styler(mode: .none)
        #expect(styler.paint("plain", Theme.lamp, bold: true) == "plain")
    }

    @Test func charts() {
        #expect(Charts.bar(1, width: 4) == "████")
        #expect(Charts.bar(0, width: 4) == "")
        #expect(Charts.block(0, minimum: true) == "▁")
        #expect(Charts.block(1, row: 0, of: 2) == "█")
        #expect(Charts.block(0.25, row: 1, of: 2) == " ")
    }

    @Test func pngEncoderRoundTripsThroughDecoder() throws {
        var raster = Raster(width: 3, height: 2, fill: 0x10192D)
        raster[1, 0] = 0xFFCC9F
        let png = try #require(PNGEncoder.encode(raster))
        let image = try PNGDecoder.decode(png)
        #expect(image.width == 3 && image.height == 2)
        #expect(image.rgba(x: 1, y: 0) == 0xFFCC_9FFF)
        #expect(image.rgba(x: 0, y: 1) == 0x1019_2DFF)
    }

    @Test func kittyPayloadIsChunked() {
        let payload = KittyGraphics.display(png: Data(repeating: 7, count: 10_000), id: 42, columns: 10, rows: 5)
        #expect(payload.hasPrefix("\u{1B}_Ga=T,f=100,i=42,c=10,r=5"))
        #expect(payload.components(separatedBy: "\u{1B}_G").count - 1 == 4)
        #expect(payload.hasSuffix("\u{1B}\\"))
    }

    @Test func colorDetection() {
        #expect(TerminalInfo.colorMode(environment: ["NO_COLOR": "1", "COLORTERM": "truecolor"], isTTY: true) == .none)
        #expect(TerminalInfo.colorMode(environment: ["COLORTERM": "truecolor"], isTTY: true) == .truecolor)
        #expect(TerminalInfo.colorMode(environment: ["TERM": "xterm-256color"], isTTY: true) == .ansi256)
        #expect(TerminalInfo.colorMode(environment: ["TERM": "xterm-256color"], isTTY: false) == .none)
        #expect(TerminalInfo.graphics(environment: ["TERM_PROGRAM": "ghostty"], isTTY: true) == .kitty)
        #expect(TerminalInfo.graphics(environment: ["TERM_PROGRAM": "iTerm.app"], isTTY: true) == .iterm2)
        #expect(TerminalInfo.graphics(environment: ["TERM_PROGRAM": "iTerm.app", "TMUX": "x"], isTTY: true) == .none)
    }

    @Test func keyParsing() {
        #expect(RawTerminal.parse([27, 91, 65]) == .up)
        #expect(RawTerminal.parse([113]) == .character("q"))
        #expect(RawTerminal.parse([3]) == .interrupt)
    }
}
