import Foundation
import DreadcastKit
import DreadTerminal

/// A place saved under a short name, for `--location <name>`, `--all` and the app's
/// Places tab.
public struct SavedPlace: Codable, Equatable, Sendable {
    public var name: String
    public var place: Place

    public init(name: String, place: Place) {
        self.name = name
        self.place = place
    }
}

/// The rules for saved places. The first place is the default.
enum PlaceBook {
    static let limit = 8

    enum Problem: LocalizedError, Equatable {
        case full
        case taken(String)
        case invalidName(String)
        case notFound(String)
        case alreadySaved(String)
        case onlyPlace

        var errorDescription: String? {
            switch self {
            case .full: "You can save up to \(PlaceBook.limit) places. Remove one with `dread places remove <name>`."
            case .taken(let name): "There’s already a place called \(name)."
            case .invalidName(let name): "“\(name)” can’t be a place name. Use up to 20 lowercase letters, digits and hyphens, starting with a letter."
            case .notFound(let name): "No saved place called \(name). Run `dread places` to list them."
            case .alreadySaved(let name): "That place is already saved as \(name)."
            case .onlyPlace: "That’s your only place. Run `dread setup` to change it."
            }
        }
    }

    static func isValidName(_ name: String) -> Bool {
        guard (1...20).contains(name.count), let first = name.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    static func index(of name: String, in places: [SavedPlace]) -> Int? {
        places.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A short name from the town: "Tampa, FL" becomes tampa, or tampa-2 when taken.
    static func suggestedName(for place: Place, avoiding places: [SavedPlace]) -> String {
        let town = place.name.components(separatedBy: ",").first ?? place.name
        var slug = ""
        for scalar in town.lowercased().folding(options: .diacriticInsensitive, locale: nil).unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug += "-"
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        slug = String(slug.prefix(16))
        if !isValidName(slug) { slug = "place" }
        var candidate = slug
        var number = 2
        while index(of: candidate, in: places) != nil {
            candidate = "\(slug)-\(number)"
            number += 1
        }
        return candidate
    }

    static func add(_ place: Place, name requested: String?, to places: [SavedPlace]) throws -> [SavedPlace] {
        if let existing = places.first(where: { $0.place.coordinate == place.coordinate }) { throw Problem.alreadySaved(existing.name) }
        guard places.count < limit else { throw Problem.full }
        let name = requested?.lowercased() ?? suggestedName(for: place, avoiding: places)
        guard isValidName(name) else { throw Problem.invalidName(requested ?? name) }
        guard index(of: name, in: places) == nil else { throw Problem.taken(name) }
        return places + [SavedPlace(name: name, place: place)]
    }

    static func remove(_ name: String, from places: [SavedPlace]) throws -> [SavedPlace] {
        guard let i = index(of: name, in: places) else { throw Problem.notFound(name) }
        guard places.count > 1 else { throw Problem.onlyPlace }
        var result = places
        result.remove(at: i)
        return result
    }

    static func makeDefault(_ name: String, in places: [SavedPlace]) throws -> [SavedPlace] {
        guard let i = index(of: name, in: places) else { throw Problem.notFound(name) }
        var result = places
        result.insert(result.remove(at: i), at: 0)
        return result
    }

    static func rename(_ old: String, to new: String, in places: [SavedPlace]) throws -> [SavedPlace] {
        guard let i = index(of: old, in: places) else { throw Problem.notFound(old) }
        let name = new.lowercased()
        guard isValidName(name) else { throw Problem.invalidName(new) }
        if let other = index(of: name, in: places), other != i { throw Problem.taken(name) }
        var result = places
        result[i].name = name
        return result
    }
}

/// One row per place: conditions, alerts, the next two hours and today. Shared by the
/// app's Places tab and `dread now --all`.
enum PlaceRows {
    struct Reading: Sendable {
        let saved: SavedPlace
        let weather: Fetched<WeatherReport>?
        let alerts: Fetched<[WeatherAlert]>?
        let nowcast: Nowcast?
    }

    static let columns = [("NAME", 11), ("PLACE", 20), ("NOW", 20), ("ALERTS", 24), ("NEXT 2 H", 20), ("TODAY", 0)]

    static func header(styler s: Styler, width: Int) -> String {
        let text = "   " + columns.map { $0.1 > 0 ? $0.0.padding($0.1) : $0.0 }.joined()
        return s.paint(TextWidth.pad(text, to: width), TextStyle(foreground: Theme.mist, background: RGB(hex: 0x182B40), bold: true))
    }

    /// The worst alert, or why there's none to show.
    enum AlertState {
        case notCovered, loading, unknown, clear
        case active(WeatherAlert, count: Int)
    }

    static func alertState(_ r: Reading) -> AlertState {
        guard r.saved.place.isUnitedStates else { return .notCovered }
        guard let fetched = r.alerts else { return .loading }
        guard let alerts = fetched.value else { return .unknown }
        guard let worst = alerts.sorted(by: WeatherAlert.threatOrder).first else { return .clear }
        return .active(worst, count: alerts.count)
    }

    static func line(_ r: Reading, ctx: Context, width: Int, highlighted: Bool, viewing: Bool) -> String {
        let s = ctx.styler
        let report = r.weather?.value
        let fmt = Formatter(units: ctx.units, timeZone: report?.timeZone ?? ctx.timeZone(for: r.saved.place))
        let town = r.saved.place.name

        var now = "…"
        if let report {
            let c = report.current
            now = ctx.icon(c.weatherCode, isDay: c.isDay) + " " + fmt.temperature(c.temperature) + " " + WeatherCondition.description(c.weatherCode)
        } else if r.weather?.value == nil, r.weather != nil {
            now = "unavailable"
        }

        let alert: (String, RGB)
        switch alertState(r) {
        case .notCovered: alert = ("— (NWS covers the US)", Theme.faint)
        case .loading: alert = ("…", Theme.faint)
        case .unknown: alert = ("unknown", Theme.advisory)
        case .clear: alert = ("none", Theme.mint)
        case .active(let worst, let count): alert = ("▲ " + worst.event + (count > 1 ? " +\(count - 1)" : ""), NowCommand.alertColor(worst))
        }

        var rain = ("—", Theme.faint)
        if let nowcast = r.nowcast {
            let text = TextWidth.strippingANSI(NowCommand.nowcastSummary(nowcast, fmt: fmt, ctx: ctx)).replacingOccurrences(of: " (radar)", with: "")
            rain = (text, nowcast.isRainingNow || nowcast.arrivalMinutes != nil ? Theme.rain : Theme.mist)
        }

        var today = ""
        if let report, let day = DayRows.upcoming(report, from: ctx.now, count: 1).first {
            today = "\(fmt.temperature(day.low))–\(fmt.temperature(day.high)) · \(Int(day.precipitationProbability ?? 0))%"
        }

        let marker = viewing ? "●" : " "
        let cells = [r.saved.name.cell(columns[0].1), town.cell(columns[1].1), now.cell(columns[2].1)]
        if highlighted {
            let text = " " + marker + " " + cells.joined() + alert.0.cell(columns[3].1) + rain.0.cell(columns[4].1) + today
            return s.paint(TextWidth.pad(TextWidth.truncate(text, to: width), to: width),
                           TextStyle(foreground: Theme.porcelain, background: RGB(hex: 0x1C3350), bold: true))
        }
        return " " + s.paint(marker, ctx.highlight) + " " + s.paint(cells[0], Theme.porcelain, bold: true) + s.paint(cells[1], Theme.mist) + cells[2]
            + s.paint(alert.0.cell(columns[3].1), alert.1) + s.paint(rain.0.cell(columns[4].1), rain.1) + s.paint(today, Theme.mist)
    }

    static func plain(_ r: Reading, ctx: Context) -> String {
        let report = r.weather?.value
        let fmt = Formatter(units: ctx.units, timeZone: report?.timeZone ?? ctx.timeZone(for: r.saved.place))
        var parts = ["\(r.saved.name) (\(r.saved.place.name)):"]
        if let report {
            parts.append("\(fmt.temperature(report.current.temperature, unit: true)), \(WeatherCondition.description(report.current.weatherCode).lowercased()).")
        } else {
            parts.append("conditions unavailable.")
        }
        switch alertState(r) {
        case .notCovered: break
        case .loading, .unknown: parts.append("Alerts unavailable.")
        case .clear: parts.append("No active alerts.")
        case .active(let worst, let count): parts.append(worst.event + (count > 1 ? " and \(count - 1) more" : "") + ".")
        }
        if let report, let day = DayRows.upcoming(report, from: ctx.now, count: 1).first {
            parts.append("Today \(fmt.temperature(day.low))–\(fmt.temperature(day.high)), \(fmt.percent(day.precipitationProbability)) chance of rain.")
        }
        return parts.joined(separator: " ")
    }
}
