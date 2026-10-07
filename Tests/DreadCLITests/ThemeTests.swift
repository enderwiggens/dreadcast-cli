import Foundation
import Testing
import DreadTerminal
@testable import DreadcastKit
@testable import DreadCLI

/// The app's theme system: scenes bring a highlight and map palette; either can be fixed.
@Suite("Themes")
struct ThemeTests {
    @Test func highlightFollowsTheScene() throws {
        #expect(try SceneTests.context(scene: "uap").highlight == Theme.violet)
        #expect(try SceneTests.context(scene: "solar-tantrum").highlight == Theme.mint)
        #expect(try SceneTests.context(scene: "asteroid").highlight == Theme.lamp)
        let fixed = try SceneTests.context(scene: "uap")
        fixed.config.highlight = "ember-red"
        #expect(fixed.highlight == RGB(hex: 0xFF697D))
    }

    @Test func highlightsTakeTheAppsNames() {
        #expect(Highlight.allCases.count == 9)
        #expect(Highlight.named("auto") == .automatic)
        #expect(Highlight.named("Signal Blue") == .signalBlue)
        #expect(Highlight.named("blue") == .signalBlue)
        #expect(Highlight.named("storm") == .superstormLime)
        #expect(Highlight.named("AI") == .aiViolet)
        #expect(Highlight.named("chartreuse") == nil)
        #expect(Highlight.automatic.color == nil)
        #expect(Highlight.allCases.filter { $0 != .automatic }.allSatisfy { $0.color != nil })
    }

    /// Spot checks against the app's style.js and MapPalette.swift.
    @Test func mapPalettesMatchTheApp() {
        #expect(MapStyle.theme(.asteroid) == MapStyle(water: 0x10192D, land: 0x252837, road: 0x656170, border: 0x716779, text: 0xE0D9D7, accent: 0xFFCC9F))
        #expect(MapStyle.theme(.clearForNow).water == 0x164451)
        #expect(MapStyle.theme(.uap).accent == 0xD8B5FF)
        #expect(MapStyle.graphite.land == 0x2D3238)
        // Every scene has its own palette, with the scene's highlight as its accent.
        #expect(Set(SceneID.allCases.map { MapStyle.theme($0).land }).count == SceneID.allCases.count)
        for scene in SceneID.allCases { #expect(MapStyle.theme(scene).accent == scene.accent.hex, "\(scene)") }
        #expect(MapChoice.named("follow-theme") == .theme && MapChoice.named("neutral") == .graphite && MapChoice.named("daylight") == nil)
        #expect(ForecastRow.named("7-day") == .days && ForecastRow.named("hourly") == .hourly && ForecastRow.named("never") == nil)
    }

    @Test func theBasemapDrawsInTheTheme() {
        func share(of color: UInt32, center: GeoCoordinate, style: MapStyle) -> Double {
            let viewport = RadarViewport(center: center, rangeMiles: 35, width: 60, height: 40)
            let base = RadarScene(viewport: viewport, palette: .dreadcast, minimumDBZ: 15, units: .imperial, style: style).base()
            return Double(base.pixels.filter { $0 == color }.count) / Double(base.pixels.count)
        }
        let atlantic = GeoCoordinate(latitude: 30, longitude: -60), kansas = GeoCoordinate(latitude: 38.5, longitude: -98.5)
        for style in [MapStyle.theme(.asteroid), .theme(.fallout), .graphite] {
            #expect(share(of: style.water, center: atlantic, style: style) > 0.8)
            #expect(share(of: style.land, center: kansas, style: style) > 0.5)
        }
    }

    @Test func markersAndTabsUseTheHighlight() throws {
        let viewport = RadarViewport(center: SceneTests.tampa.coordinate, rangeMiles: 35, width: 60, height: 40)
        let scene = RadarScene(viewport: viewport, palette: .dreadcast, minimumDBZ: 15, units: .imperial, style: .graphite, highlight: Theme.violet)
        let marker = scene.overlays(placeName: "Tampa, FL", strikes: [], now: Date()).first { $0.character == "✛" }
        #expect(marker?.color == Theme.violet)
        let styler = Styler(mode: .truecolor)
        let tabs = DreadApp.tabs(active: .radar, alerts: [], width: 120, styler: styler, highlight: Theme.mint)
        #expect(tabs.contains("48;2;173;242;209"))
    }
}
