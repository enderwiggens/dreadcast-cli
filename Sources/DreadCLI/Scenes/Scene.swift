import Foundation
import DreadcastKit
import DreadTerminal

/// The app's free scene themes, drawn as pixel art. Scenes are decorative, as in the
/// app: they never describe the actual weather, which stays in the readings beside them.
public enum SceneID: String, CaseIterable, Sendable {
    case asteroid
    case deepTrouble = "deep-trouble"
    case aiUprising = "ai-uprising"
    case solarTantrum = "solar-tantrum"
    case fallout
    case superstorm
    case clearForNow = "clear-for-now"
    case uap

    public var title: String {
        switch self {
        case .asteroid: "Asteroid Watch"
        case .deepTrouble: "Deep Trouble"
        case .aiUprising: "AI Uprising"
        case .solarTantrum: "Solar Tantrum"
        case .fallout: "Fallout Outlook"
        case .superstorm: "Superstorm"
        case .clearForNow: "Clear for Now"
        case .uap: "UAP Invasion"
        }
    }

    /// The scene's highlight color, matching the app's accent for each theme.
    public var accent: RGB {
        switch self {
        case .asteroid, .clearForNow: Theme.lamp
        case .aiUprising, .uap: Theme.violet
        case .solarTantrum, .deepTrouble: Theme.mint
        case .fallout: RGB(hex: 0xF8D599)
        case .superstorm: Theme.lime
        }
    }

    /// One approved line per time of day, from the brand guide's scene copy and taglines.
    public func line(for period: ScenePeriod) -> String {
        switch (self, period) {
        case (.asteroid, .dawn): "Your 9 AM remains scheduled."
        case (.asteroid, .day): "An interesting sky today."
        case (.asteroid, .dusk): "A scheduling conflict with oblivion."
        case (.asteroid, .night): "Still expected at standup."
        case (.aiUprising, .dawn): "Within expected parameters."
        case (.aiUprising, .day): "Administrator access requested."
        case (.aiUprising, .dusk): "They’ve stopped saying please."
        case (.aiUprising, .night): "Scattered laser activity after midnight."
        case (.solarTantrum, .dawn): "Some interference with everything."
        case (.solarTantrum, .day): "The sun is expressing itself."
        case (.solarTantrum, .dusk): "A beautiful evening to lose electricity."
        case (.solarTantrum, .night): "The transformers are expressing themselves."
        case (.fallout, .dawn): "Comfortingly uneventful."
        case (.fallout, .day): "Outdoor plans under review."
        case (.fallout, .dusk): "An unusual shade of evening."
        case (.fallout, .night): "A lovely evening to have walls."
        case (.superstorm, .dawn): "A little weather on the way."
        case (.superstorm, .day): "The sky has chosen green."
        case (.superstorm, .dusk): "A good day to have an inside."
        case (.superstorm, .night): "The patio furniture has departed."
        case (.deepTrouble, _): "The outlook could be better."
        case (.uap, _): "There’s a lot in the forecast."
        case (.clearForNow, _): "At least you’ll know what to wear."
        }
    }

    /// Pro themes stay in the app, like the Pro radar palettes.
    static let proTitles: [String: String] = [
        "black-hole": "Black Hole", "blackhole": "Black Hole",
        "botanical": "Botanical Takeover", "botanical-takeover": "Botanical Takeover",
        "peak-optimism": "Peak Optimism", "mountains": "Peak Optimism",
        "volcano": "Volcano Watch", "volcano-watch": "Volcano Watch"
    ]

    static let aliases: [String: SceneID] = [
        "asteroid-watch": .asteroid, "deeptrouble": .deepTrouble, "kraken": .deepTrouble,
        "ai": .aiUprising, "solar": .solarTantrum, "fallout-outlook": .fallout,
        "storm": .superstorm, "clear": .clearForNow, "beach": .clearForNow,
        "uap-invasion": .uap, "ufo": .uap
    ]

    public enum Lookup: Equatable {
        case scene(SceneID)
        case pro(String)
        case unknown
    }

    public static func lookup(_ name: String) -> Lookup {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "_", with: "-")
        if let scene = SceneID(rawValue: key) ?? aliases[key] { return .scene(scene) }
        if let title = proTitles[key] { return .pro(title) }
        return .unknown
    }

    /// A different scene each day, the same one all day.
    public static func daily(on date: Date, timeZone: TimeZone) -> SceneID {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Count days from the local calendar date, so the scene changes at local midnight.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = utc.date(from: calendar.dateComponents([.year, .month, .day], from: date)) ?? date
        let day = Int((midnight.timeIntervalSince1970 / 86400).rounded(.down))
        return allCases[((day % allCases.count) + allCases.count) % allCases.count]
    }

    public func adjacent(_ offset: Int) -> SceneID {
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[((index + offset) % all.count + all.count) % all.count]
    }

    public static var names: String { allCases.map(\.rawValue).joined(separator: ", ") }
}

/// The four story stages. Each scene escalates from dawn to night, as in the app.
public enum ScenePeriod: String, CaseIterable, Sendable {
    case dawn, day, dusk, night

    public var title: String { rawValue.capitalized }

    /// The app's automatic schedule, by local hour at the location.
    public static func at(_ date: Date, timeZone: TimeZone) -> ScenePeriod {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch calendar.component(.hour, from: date) {
        case 5..<8: return .dawn
        case 8..<17: return .day
        case 17..<20: return .dusk
        default: return .night
        }
    }

    public var next: ScenePeriod {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}
