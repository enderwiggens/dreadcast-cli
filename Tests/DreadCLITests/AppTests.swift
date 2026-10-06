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

    @Test func tabsHaveNamesAndNumbers() {
        #expect(AppTab.named("radar") == .radar)
        #expect(AppTab.named("Forecast") == .forecast)
        #expect(AppTab.named("3") == .radar)
        #expect(AppTab.named("8") == .scene)
        #expect(AppTab.named("top") == .systems)
        #expect(AppTab.named("10") == nil)
        #expect(AppTab.named("tornado") == nil)
    }

    static func snapshot(alerts: [WeatherAlert]? = []) -> TopCommand.Snapshot {
        var snapshot = TopCommand.Snapshot()
        snapshot.weather = SceneTests.fetched(VoiceTests.report(code: 1))
        snapshot.alerts = SceneTests.fetched(alerts)
        return snapshot
    }

    static func frame(_ ctx: Context, _ snapshot: TopCommand.Snapshot, width: Int, height: Int) -> AppFrame {
        AppFrame(ctx: ctx, place: SceneTests.tampa, snapshot: snapshot, width: width, height: height, elapsed: 7)
    }

    /// Every view except radar, which loads tiles, fits any body size with or without data.
    @Test func viewsFitTheirBody() throws {
        let ctx = try SceneTests.context()
        let views: [AppView] = [NowView(), SystemsView(), ForecastView(), AlertsView(), OutlookView(), LightningView(), SceneView(ctx: ctx)]
        for view in views {
            for snapshot in [TopCommand.Snapshot(), Self.snapshot(), Self.snapshot(alerts: [SceneTests.warning()])] {
                for (width, height) in [(60, 7), (80, 19), (120, 40), (200, 60)] {
                    switch view.body(Self.frame(ctx, snapshot, width: width, height: height)) {
                    case .lines(let lines):
                        #expect(lines.count <= height, "\(type(of: view)) at \(width)x\(height)")
                    case .pixels(let art, let below):
                        #expect(art.columns == width)
                        #expect(art.rows + below.count <= height + 1, "\(type(of: view)) at \(width)x\(height)")
                    }
                }
            }
        }
    }

    @Test func nowShowsTheSceneOnlyWhenClearAndTall() throws {
        let ctx = try SceneTests.context()
        func hasBanner(_ snapshot: TopCommand.Snapshot, height: Int) -> Bool {
            guard case .lines(let lines) = NowView().body(Self.frame(ctx, snapshot, width: 100, height: height)) else { return false }
            return lines.contains { $0.contains("▀") }
        }
        #expect(hasBanner(Self.snapshot(), height: 40))
        #expect(!hasBanner(Self.snapshot(), height: 24))
        #expect(!hasBanner(Self.snapshot(alerts: [SceneTests.warning()]), height: 40))
        #expect(!hasBanner(Self.snapshot(alerts: nil), height: 40))
        let off = try SceneTests.context(banner: false)
        guard case .lines(let lines) = NowView().body(Self.frame(off, Self.snapshot(), width: 100, height: 40)) else { return }
        #expect(!lines.contains { $0.contains("▀") })
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
        let calm = DreadApp.header(tab: .now, frame: Self.frame(ctx, Self.snapshot(), width: 120, height: 30), styler: ctx.styler)
            .map(TextWidth.strippingANSI)
        #expect(calm.count == DreadApp.headerRows)
        #expect(calm[1].contains("1 Now") && calm[1].contains("8 Scene") && !calm[1].contains("Alerts 1"))
        let warned = DreadApp.header(tab: .now, frame: Self.frame(ctx, Self.snapshot(alerts: [SceneTests.warning()]), width: 120, height: 30),
                                     styler: ctx.styler).map(TextWidth.strippingANSI)
        #expect(warned[0].contains("▲"))
        #expect(warned[1].contains("Alerts 1"))
        // Narrow terminals keep every tab's number and the active tab's name.
        let narrow = TextWidth.strippingANSI(DreadApp.tabs(active: .radar, alerts: [SceneTests.warning()], width: 60, styler: ctx.styler))
        #expect(TextWidth.of(narrow) <= 60)
        #expect(narrow.contains("3 Radar") && narrow.contains("8") && narrow.contains(" 1") && !narrow.contains("Scene"))
        #expect(narrow.contains("5 1"))
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
}
