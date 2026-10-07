import Foundation
import DreadTerminal

// The Mac app's theme system, carried over: each scene brings a highlight color and a
// map palette, and either can be fixed instead. Values match the app
// (RadarBar/DreadcastTheme.swift, RadarBarCore/MapPalette.swift and
// Resources/MapPreview/style.js); keep them in sync when the app changes.

/// The accent for controls, the selected tab and the map marker. Automatic follows the
/// scene. Hazard, alert, radar and lightning colors never change with it.
enum Highlight: String, CaseIterable, Sendable {
    case automatic = "auto"
    case signalBlue = "signal-blue"
    case solarMint = "solar-mint"
    case superstormLime = "superstorm-lime"
    case falloutGold = "fallout-gold"
    case lampGlow = "lamp-glow"
    case emberRed = "ember-red"
    case afterglowPink = "afterglow-pink"
    case aiViolet = "ai-violet"

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .signalBlue: "Signal Blue"
        case .solarMint: "Solar Mint"
        case .superstormLime: "Superstorm Lime"
        case .falloutGold: "Fallout Gold"
        case .lampGlow: "Lamp Glow"
        case .emberRed: "Ember Red"
        case .afterglowPink: "Afterglow Pink"
        case .aiViolet: "AI Violet"
        }
    }

    /// The fixed color, or nil for Automatic.
    var color: RGB? {
        switch self {
        case .automatic: nil
        case .signalBlue: Theme.information
        case .solarMint: Theme.mint
        case .superstormLime: Theme.lime
        case .falloutGold: RGB(hex: 0xF8D599)
        case .lampGlow: Theme.lamp
        case .emberRed: RGB(hex: 0xFF697D)
        case .afterglowPink: Theme.urgent
        case .aiViolet: Theme.violet
        }
    }

    /// A highlight by its name or the short name the app shows.
    static func named(_ name: String) -> Highlight? {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "-")
        let short: [String: Highlight] = [
            "automatic": .automatic, "blue": .signalBlue, "signal": .signalBlue, "mint": .solarMint, "solar": .solarMint,
            "lime": .superstormLime, "storm": .superstormLime, "gold": .falloutGold, "fallout": .falloutGold,
            "lamp": .lampGlow, "red": .emberRed, "ember": .emberRed, "pink": .afterglowPink, "afterglow": .afterglowPink,
            "violet": .aiViolet, "ai": .aiViolet,
        ]
        return Highlight(rawValue: key) ?? short[key]
    }

    static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

/// Basemap colors for the radar. "Follow theme" uses the scene's palette from the app;
/// Graphite is the app's neutral one.
struct MapStyle: Equatable, Sendable {
    let water: UInt32
    let land: UInt32
    let road: UInt32
    let border: UInt32
    let text: UInt32
    let accent: UInt32

    var coast: UInt32 { border }
    var stateBorder: UInt32 { Raster.mix(land, border, 0.55) }
    var ring: UInt32 { Raster.mix(land, road, 0.7) }
    var label: RGB { RGB(hex: Raster.mix(land, text, 0.72)) }
    var placeLabel: RGB { RGB(hex: text) }

    static func theme(_ scene: SceneID) -> MapStyle {
        switch scene {
        case .asteroid: MapStyle(water: 0x10192D, land: 0x252837, road: 0x656170, border: 0x716779, text: 0xE0D9D7, accent: 0xFFCC9F)
        case .deepTrouble: MapStyle(water: 0x0D2431, land: 0x253A40, road: 0x638588, border: 0x74948F, text: 0xDDEEEE, accent: 0xADF2D1)
        case .aiUprising: MapStyle(water: 0x171529, land: 0x2B2540, road: 0x736180, border: 0x776885, text: 0xE5DCEE, accent: 0xD8B5FF)
        case .solarTantrum: MapStyle(water: 0x10252B, land: 0x233B3A, road: 0x5E7B70, border: 0x718F7C, text: 0xDDEDE4, accent: 0xADF2D1)
        case .fallout: MapStyle(water: 0x211E29, land: 0x38302F, road: 0x837560, border: 0x8A7D67, text: 0xEBE1CB, accent: 0xF8D599)
        case .superstorm: MapStyle(water: 0x10212F, land: 0x23323D, road: 0x657C79, border: 0x778883, text: 0xDFE8D9, accent: 0xD9EF9B)
        case .clearForNow: MapStyle(water: 0x164451, land: 0x404A44, road: 0xA59B7B, border: 0x727B6A, text: 0xEBE5D4, accent: 0xFFCC9F)
        case .uap: MapStyle(water: 0x151D31, land: 0x272D3B, road: 0x7B7B88, border: 0x868393, text: 0xE5E6ED, accent: 0xD8B5FF)
        }
    }

    static let graphite = MapStyle(water: 0x171B21, land: 0x2D3238, road: 0x626A73, border: 0x747D86, text: 0xDDE0E5, accent: 0xB7C0C9)
}

/// Which basemap the radar draws on.
enum MapChoice: String, CaseIterable, Sendable {
    case theme, graphite

    static func named(_ name: String) -> MapChoice? {
        let key = name.lowercased()
        return MapChoice(rawValue: key) ?? (["follow-theme", "auto", "automatic", "scene"].contains(key) ? .theme : key == "neutral" ? .graphite : nil)
    }
}

/// What sits beside the radar's timeline on the Now tab, like the app's header forecast.
enum ForecastRow: String, CaseIterable, Sendable {
    case days, hourly, off

    static func named(_ name: String) -> ForecastRow? {
        let key = name.lowercased()
        return ForecastRow(rawValue: key) ?? (["7-day", "weekly", "daily"].contains(key) ? .days : key == "hours" ? .hourly : nil)
    }
}

extension Context {
    /// The scene the highlight and map follow: yours, or today's with `daily`.
    var themeScene: SceneID { SceneCommand.configuredScene(self, timeZone: .current) }

    /// The accent for controls and markers.
    var highlight: RGB { Highlight.named(config.highlight)?.color ?? themeScene.accent }

    /// The radar's basemap colors.
    var mapStyle: MapStyle { MapChoice.named(config.map) == .graphite ? .graphite : .theme(themeScene) }
}
