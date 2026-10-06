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
        #expect(RawTerminal.parse([9]) == .tab)
        #expect(RawTerminal.parse([27, 91, 90]) == .backTab)
        #expect(RawTerminal.parse([27, 91, 53, 126]) == .pageUp)
        #expect(RawTerminal.parse([27, 91, 54, 126]) == .pageDown)
        #expect(RawTerminal.parse([27, 91, 72]) == .home)
    }

    /// Several keys can arrive in one read: key repeat, fast typing or a paste.
    @Test func inputSplitsIntoKeys() {
        #expect(RawTerminal.keys(Array("jj".utf8)) == [.character("j"), .character("j")])
        #expect(RawTerminal.keys([27, 91, 66, 27, 91, 66]) == [.down, .down])
        #expect(RawTerminal.keys([27, 91, 53, 126, 113]) == [.pageUp, .character("q")])
        #expect(RawTerminal.keys(Array("é]".utf8)) == [.character("é"), .character("]")])
        // SS3 arrows, from terminals in application mode.
        #expect(RawTerminal.keys([27, 79, 65]) == [.up])
        // Alt with a key never reads as Esc, which would quit.
        #expect(RawTerminal.keys([27, 113]) == [.character("q")])
        #expect(RawTerminal.keys([27]) == [.escape])
        #expect(RawTerminal.keys([9, 13, 3]) == [.tab, .enter, .interrupt])
        #expect(RawTerminal.keys([]) == [])
    }
}

@Suite("Compression")
struct CompressionTests {
    @Test func deflateRoundTripsThroughInflate() throws {
        var samples: [[UInt8]] = [[], [42], Array("dreadcast".utf8)]
        samples.append([UInt8](repeating: 7, count: 100_000))                       // long runs
        samples.append((0..<70_000).map { UInt8(($0 * 31 + $0 / 7) & 0xFF) })        // varied data
        var radar = [UInt8]()                                                        // RGB rows with a filter byte
        for y in 0..<200 {
            radar.append(0)
            for x in 0..<300 { radar.append(contentsOf: (x / 40 + y / 30) % 2 == 0 ? [16, 25, 45] : [99, 200, 185]) }
        }
        samples.append(radar)
        for sample in samples {
            let compressed = Deflate.zlib(sample)
            #expect(try Inflate.zlib(compressed) == sample)
        }
        #expect(Deflate.zlib(radar).count < radar.count / 10)
    }

    @Test func inflateReadsZlibStreamsFromOtherEncoders() throws {
        // Python zlib level 9 chose a dynamic-Huffman block (BTYPE 2) for this text.
        let expected = Array((0..<400).map { "radar\(($0 * 7) % 97) storm\(($0 * 13) % 31)" }.joined(separator: " ").utf8)
        let dynamic = [UInt8](Data(base64Encoded: Self.dynamicFixture)!)
        #expect((dynamic[2] >> 1) & 3 == 2)
        #expect(try Inflate.zlib(dynamic) == expected)
        // Python zlib level 0: an uncompressed stored block.
        let stored = [UInt8](Data(base64Encoded: "eAEBBgD5/3N0b3JlZAk8ApI=")!)
        #expect(try Inflate.zlib(stored) == Array("stored".utf8))
    }

    static let dynamicFixture = "eNpdmFuqJEcMBbcyS6iTUj5qOQP+NYY73j/GlJQQ5zPpm4Omgg511M/vv37/PL/+/PvPz9/Pr5//T/s7Kb6j8juP9Z2HvvOp46mP9Z1jfue6naP+tbqdb/35+53nqs/r+or6PGuYmq2u7x6urp8arm6/NZvqdh3Hrr/+jnVXNekY9T+pUevuqElVl6MmjXpMWZOqrs+adMw616h1ffVj7Kfcs9WxZlPdPj1cPea3n2Ndr+Oox1yz1mX1Q21GAcDxkHBsEs4E4SkSngeE1yThPUh4vyR8Fgm/AcJBwHoAWJuAR5JwCIjjEHFOIJ6DiOdLxGsR8Q4iPg8Qn03EbwJxkrBEwjpGeBJxDDCOl4xzgfEMMl4PGa8NxjvJ+AiMzyHjd9q3mIg1iFgvEI9FxhFgnA8Z5ybjmWC8RMbrgPGeZHwGGZ+XjN9FxguIFUQ8HiAem4wjyThFxnnIeE4wXoOM10tRLzI+QcbvA8YPEW8QbsvLLN+EW/MyzTfi9rxpXq55Wl5m+UbcmjfLN+LWPC0vWr4Bt+Zlmm/A7XnT/DDNm+Vllm/CrXm55oOeN83LNE/Li5Zvvq15s/zdxA8It+Vllr/fYZFwa74Jt+dN83LN0/Iyy19RcxU/BNyaN8vLLN+IW/Myzd9VPIC4NT9M82Z5meUbcWtervmA503zMs2b5WWWb8atebP83cXBXfyQcVv+7uK0XSwybs+b5mWap+Vllm/ErXmz/N3FDxi35WWWv7tYZNyab8btedP8MM2b5UXL310ctosfIm7Pm+ZlmjfLyyx/d/EA47b8FfXiLg7bxQ8ZP0S8bRUnV7FI+GqelpdZvhG35s3ydxUHV/FDxG35u4rTVrGIWCRMwPfXPC0vs3wTbs3LNR/0vGlepnmzvMzyTbg1b5ZvwgOAX/Jty99NHLaJHxJuz5vm5Zqn5WWWv5t4gHBbvgm35s3youXvKn4IuDV/V3FyFYuI7695Wl5m+UbcmpdrPuh507xM82Z50fJ3F7OKZVU8WMVhVRxWxWlVPK2KF6t4WRVvVvGxKm7LN+PWPC1/dzGzWJbFw7I4LIvTsjiZxdOyeDGLl2Xxtiw+lsVX80HPU/MyzZvlZZa/u5hdnNbFyS6e1sXLunhZF2/r4sMubs3LNM93Nmb5u4qZxcOyOJjFaVmclsXTsnhZFm9m8bYsPszi+86Glr+ECVhWxYNVPKyKg1WcVsXTqniyipdV8WYVb6viY1V839lQ8/fFB/jKongwisOiOCyKk1E8LYono3hZFG+L4m1RfCyK2/PU/DDNm+Vllr+r2KI4LIqTUTwtiiejeFkUb4viwyi+72xEzdPyMss3YVkVD6viYBWHVXGyiqdV8bIqXqzibVV8WMX3nY1Z/n6LbRdbFotZPCyLg1mclsVpWTwti5dl8WIWb8viwyy+72zM8vcHNXexdfFgFw/r4rAuTuvitC6e7OJlXbzYxdu6+FgXt+Zp+UbMLJZl8bAsHpbFYVmczOK0LJ7M4mVZvC2L76v55z8T/ijP"

    @Test func inflateRejectsCorruptData() {
        #expect(throws: (any Error).self) { _ = try Inflate.zlib([0x78, 0x9C, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]) }
        #expect(throws: Inflate.Failure.truncated) { _ = try Inflate.zlib([0x78, 0x9C]) }
    }
}
