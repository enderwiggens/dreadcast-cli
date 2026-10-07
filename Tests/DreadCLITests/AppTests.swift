import Foundation
import Testing
import DreadcastKit
import DreadTerminal
@testable import DreadCLI

@Suite("App")
struct AppTests {
    @Test func plainDreadOpensTheAppOnlyAtATerminal() throws {
        #expect(try Arguments.parse([]).commandGiven == false)
        #expect(try Arguments.parse(["now"]).commandGiven)
        #expect(try Arguments.parse(["--location", "33602"]).commandGiven == false)
        #expect(try SceneTests.context(arguments: Arguments.parse([])).opensApp)
        #expect(try SceneTests.context(arguments: Arguments.parse(["now"])).opensApp == false)
        #expect(try SceneTests.context(arguments: Arguments.parse(["weather"])).opensApp == false)
        #expect(try SceneTests.context(arguments: Arguments.parse(["--plain"])).opensApp == false)
        #expect(try SceneTests.context(arguments: Arguments.parse(["--json"])).opensApp == false)
        #expect(try SceneTests.context(arguments: Arguments.parse(["--pretty"])).opensApp == false)
    }

    @Test func radarIsHome() {
        #expect(AppTab.allCases.prefix(3) == [.radar, .systems, .forecast])
        #expect(AppTab.named("now") == .radar)
    }

    @Test func tabsHaveNamesAndNumbers() {
        #expect(AppTab.named("radar") == .radar)
        #expect(AppTab.named("Forecast") == .forecast)
        #expect(AppTab.named("1") == .radar)
        #expect(AppTab.named("2") == .systems)
        #expect(AppTab.named("7") == .scene)
        #expect(AppTab.named("top") == .systems)
        #expect(AppTab.named("9") == nil)
        #expect(AppTab.named("tornado") == nil)
    }

    static func snapshot(alerts: [WeatherAlert]? = []) -> LiveData.Snapshot {
        var snapshot = LiveData.Snapshot()
        snapshot.weather = SceneTests.fetched(VoiceTests.report(code: 1))
        snapshot.alerts = SceneTests.fetched(alerts)
        return snapshot
    }

    static func frame(_ ctx: Context, _ snapshot: LiveData.Snapshot, width: Int, height: Int) -> AppFrame {
        AppFrame(ctx: ctx, place: SceneTests.tampa, snapshot: snapshot, width: width, height: height, elapsed: 7)
    }

    static func radar(_ ctx: Context) -> RadarView {
        let view = RadarView(ctx: ctx)
        view.radar.fixture = { RadarPanel.basemapLoop($0, width: $1, rows: $2) }
        return view
    }

    /// Every view fits any body size with or without data; radar draws the basemap.
    @Test func viewsFitTheirBody() throws {
        let ctx = try SceneTests.context()
        let views: [AppView] = [Self.radar(ctx), SystemsView(), ForecastView(), AlertsView(), OutlookView(), LightningView(), SceneView(ctx: ctx)]
        for view in views {
            for snapshot in [LiveData.Snapshot(), Self.snapshot(), Self.snapshot(alerts: [SceneTests.warning()])] {
                for (width, height) in [(60, 7), (80, 19), (120, 40), (200, 60)] {
                    switch view.body(Self.frame(ctx, snapshot, width: width, height: height)) {
                    case .lines(let lines):
                        #expect(lines.count <= height, "\(type(of: view)) at \(width)x\(height)")
                    case .pixels(let art, let above, let below):
                        #expect(art.columns == width)
                        #expect(above.count + art.rows + below.count <= height + 1, "\(type(of: view)) at \(width)x\(height)")
                    }
                }
            }
        }
    }

    /// Now is the readings, then radar filling the rest, then the timeline and coming
    /// days. The scene stays on its own tab; without room for radar, or without color,
    /// Now falls back to the quick look's text, still without the scene.
    @Test func nowIsTheRadarPanel() throws {
        let ctx = try SceneTests.context()
        func layout(_ snapshot: LiveData.Snapshot, _ context: Context? = nil, height: Int)
            -> (above: [String], below: [String], art: HalfBlockFrame?, lines: [String]) {
            let c = context ?? ctx
            switch Self.radar(c).body(Self.frame(c, snapshot, width: 100, height: height)) {
            case .pixels(let art, let above, let below): return (above, below, art, [])
            case .lines(let lines): return ([], [], nil, lines)
            }
        }
        let full = layout(Self.snapshot(), height: 40)
        #expect(!full.above.contains { $0.contains("▀") })
        let readings = full.above.map(TextWidth.strippingANSI).joined(separator: "\n")
        #expect(readings.contains("75°F") && readings.contains("No active alerts") && readings.contains("Next 2 h"))
        let art = try #require(full.art)
        #expect(full.above.count + art.rows + full.below.count == 40)
        #expect(art.rows >= 30)
        #expect(TextWidth.strippingANSI(full.below[0]).contains("◀"))
        #expect(TextWidth.strippingANSI(full.below[1]).contains("dBZ"))

        // Alerts sit above the radar, and unknown alerts never read as clear.
        let warned = layout(Self.snapshot(alerts: [SceneTests.warning()]), height: 40)
        #expect(warned.above.map(TextWidth.strippingANSI).joined().contains("TORNADO WARNING"))
        #expect(warned.art != nil)
        let unknown = layout(Self.snapshot(alerts: nil), height: 40)
        #expect(unknown.above.map(TextWidth.strippingANSI).joined().contains("not an all-clear"))

        // Short windows keep the radar until there's no room, then show text.
        let short = layout(Self.snapshot(), height: 16)
        #expect(short.art != nil)
        let tiny = layout(Self.snapshot(), height: 12)
        #expect(tiny.art == nil && tiny.lines.count <= 12 && tiny.lines.map(TextWidth.strippingANSI).joined().contains("75°F"))
        #expect(!tiny.lines.contains { $0.contains("▀") })
        let plain = layout(Self.snapshot(), try SceneTests.context(arguments: Arguments.parse(["--no-color"])), height: 40)
        #expect(plain.art == nil && plain.lines.map(TextWidth.strippingANSI).joined().contains("75°F"))
    }

    @Test func nowWaitsForRadarWithoutLosingItsPlace() throws {
        let ctx = try SceneTests.context()
        guard case .lines(let lines) = RadarView(ctx: ctx).body(Self.frame(ctx, Self.snapshot(), width: 100, height: 40)) else {
            Issue.record("expected text while radar loads"); return
        }
        #expect(lines.count == 40)
        #expect(lines.map(TextWidth.strippingANSI).contains { $0.contains("Loading radar") })
    }

    @Test func scrollingStopsAtTheEnd() throws {
        let ctx = try SceneTests.context()
        let view = AlertsView()
        let f = Self.frame(ctx, Self.snapshot(alerts: [SceneTests.warning(), SceneTests.warning()]), width: 80, height: 8)
        guard case .lines(let first) = view.body(f) else { Issue.record("expected text"); return }
        #expect(view.handle(.end, frame: f))
        guard case .lines(let last) = view.body(f) else { return }
        #expect(first != last)
        #expect(view.offset == view.lastCount - 8)
        #expect(view.handle(.home, frame: f))
        _ = view.body(f)
        #expect(view.offset == 0)
        #expect(!view.handle(.character("x"), frame: f))
    }

    @Test func theHeaderCountsAlerts() throws {
        let ctx = try SceneTests.context()
        let calm = DreadApp.header(tab: .radar, frame: Self.frame(ctx, Self.snapshot(), width: 120, height: 30), styler: ctx.styler)
            .map(TextWidth.strippingANSI)
        #expect(calm.count == DreadApp.headerRows)
        #expect(calm[1].contains("1 Radar") && calm[1].contains("7 Scene") && !calm[1].contains("Now") && !calm[1].contains("Alerts 1"))
        let warned = DreadApp.header(tab: .radar, frame: Self.frame(ctx, Self.snapshot(alerts: [SceneTests.warning()]), width: 120, height: 30),
                                     styler: ctx.styler).map(TextWidth.strippingANSI)
        #expect(warned[0].contains("▲"))
        #expect(warned[1].contains("Alerts 1"))
        // Narrow terminals keep every tab's number and the active tab's name.
        let narrow = TextWidth.strippingANSI(DreadApp.tabs(active: .radar, alerts: [SceneTests.warning()], width: 60, styler: ctx.styler))
        #expect(TextWidth.of(narrow) <= 60)
        #expect(narrow.contains("1 Radar") && narrow.contains("7") && narrow.contains(" 2") && !narrow.contains("Scene"))
        #expect(narrow.contains("4 1"))
    }

    /// The screen rewrites only the rows that changed between frames.
    @Test func theScreenRedrawsOnlyChanges() throws {
        let ctx = try SceneTests.context()
        var screen = AppScreen()
        let view = SystemsView()
        let f = Self.frame(ctx, Self.snapshot(), width: 100, height: 30)
        let first = screen.draw(tab: .systems, view: view, frame: f, styler: ctx.styler)
        let again = screen.draw(tab: .systems, view: view, frame: f, styler: ctx.styler)
        #expect(first.contains(TerminalControl.clearScreen))
        #expect(again.count < first.count / 4)
        let wider = screen.draw(tab: .systems, view: view, frame: Self.frame(ctx, Self.snapshot(), width: 110, height: 30), styler: ctx.styler)
        #expect(wider.contains(TerminalControl.clearScreen))
        let bigger = screen.draw(tab: .systems, view: view, frame: Self.frame(ctx, Self.snapshot(), width: 100, height: 34), styler: ctx.styler)
        #expect(bigger.contains(TerminalControl.clearScreen))
    }

    // MARK: Small windows and no color

    @Test func smallWindowsGetANote() {
        var screen = AppScreen()
        let styler = Styler(mode: .none)
        let note = screen.tooSmall(columns: 40, rows: 10, styler: styler)
        #expect(note.contains("at least 60×16") && note.contains("40×10"))
        #expect(screen.tooSmall(columns: 40, rows: 10, styler: styler).isEmpty)
        #expect(!screen.tooSmall(columns: 50, rows: 10, styler: styler).isEmpty)
    }

    /// Without color, the scene explains itself and radar falls back to the readings.
    @Test func pixelViewsExplainWithoutColor() throws {
        let ctx = try SceneTests.context(arguments: Arguments.parse(["--no-color"]))
        let f = Self.frame(ctx, Self.snapshot(), width: 100, height: 30)
        guard case .lines(let scene) = SceneView(ctx: ctx).body(f) else { Issue.record("expected a note"); return }
        #expect(scene.joined().contains("256 colors"))
        guard case .lines(let radar) = RadarView(ctx: ctx).body(f) else { Issue.record("expected text"); return }
        #expect(radar.map(TextWidth.strippingANSI).joined().contains("75°F"))
    }
}
