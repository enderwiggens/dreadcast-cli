import Foundation
import Testing
@testable import DreadTerminal

@Suite("Pixel art frames")
struct FrameTests {
    static func raster(_ fill: UInt32 = 0x102030) -> Raster { Raster(width: 6, height: 4, fill: fill) }

    @Test func fullFrameMatchesTheHalfBlockRenderer() {
        var raster = Self.raster()
        raster[1, 0] = 0xFFCC9F
        raster[4, 3] = 0x9CF0C8
        let styler = Styler(mode: .truecolor)
        #expect(HalfBlockFrame(raster: raster).lines(styler: styler).map(TextWidth.strippingANSI)
                == HalfBlockRenderer.render(raster, styler: styler).map(TextWidth.strippingANSI))
    }

    @Test func updatesRedrawOnlyWhatChanged() {
        let styler = Styler(mode: .truecolor)
        let first = HalfBlockFrame(raster: Self.raster())
        let full = first.update(from: nil, styler: styler)
        #expect(full.contains("\u{1B}[1;1H") && full.contains("\u{1B}[2;1H"))
        #expect(first.update(from: first, styler: styler).isEmpty)

        var changed = Self.raster()
        changed[4, 3] = 0xFFFFFF   // second cell row, fifth column
        let update = HalfBlockFrame(raster: changed).update(from: first, styler: styler, row: 3, column: 5)
        #expect(update.hasPrefix("\u{1B}[4;9H"))
        #expect(!update.contains("\u{1B}[3;"))
        // One cell repainted: a single half block.
        #expect(update.filter { $0 == "▀" || $0 == " " }.count == 1)
    }

    @Test func updatesAcrossLongUnchangedStretches() {
        // A change followed by many unchanged cells, then another change on the same row.
        let styler = Styler(mode: .truecolor)
        let wide = Raster(width: 40, height: 2, fill: 0x102030)
        var changed = wide
        changed[2, 0] = 0xFFFFFF
        changed[30, 1] = 0xFFFFFF
        let update = HalfBlockFrame(raster: changed).update(from: HalfBlockFrame(raster: wide), styler: styler)
        #expect(update.contains("\u{1B}[1;3H") && update.contains("\u{1B}[1;31H"))
        #expect(update.filter { $0 == "▀" || $0 == " " }.count == 2)
    }

    @Test func overlaysCarryTextAndItalics() {
        let overlays = CellOverlay.text("hi", column: 0, row: 0, color: RGB(hex: 0xEEF0F5), italic: true)
        let line = HalfBlockFrame(raster: Self.raster(), overlays: overlays).lines(styler: Styler(mode: .truecolor))[0]
        #expect(line.contains("\u{1B}[3m"))
        #expect(TextWidth.strippingANSI(line).hasPrefix("hi"))
    }

    @Test func steppedLightAndGlowsStayInBounds() {
        var raster = Self.raster(0)
        raster.glow(cx: 0, cy: 0, radius: 20, color: 0xFFFFFF, strength: 1)
        raster.blendStepped(-1, -1, 0xFFFFFF, alpha: 1)
        raster.plot(99, 99, 0xFFFFFF)
        #expect(raster[0, 0] != 0)
        raster.ditheredGradient([0x000000, 0xFFFFFF], top: 0, bottom: 4)
        #expect(raster[0, 0] == 0x000000 && raster[0, 3] == 0xFFFFFF)
    }
}
