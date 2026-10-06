import Foundation
import DreadcastKit
import DreadTerminal

/// `dread forecast`: hourly and 7-day charts from Open-Meteo.
enum ForecastCommand {
    static func run(_ ctx: Context) async throws -> ExitCode {
        let place = try await ctx.resolveLocation()
        let fetched = await ctx.weather(place)
        guard let report = fetched.value else {
            return ctx.fail("The forecast is unavailable: \(fetched.error ?? "unknown error").", code: .unavailable)
        }
        let fmt = Formatter(units: ctx.units, timeZone: report.timeZone)
        let width = min(max(ctx.terminal.columns - 2, 60), 130)
        let requested = max(1, min(48, ctx.arguments.integer("hours") ?? 12))
        let hours = report.hours(from: ctx.now, count: ctx.mode == .pretty ? min(requested, max(6, (width - 12) / 5)) : requested)
        let days = Array(report.daily.prefix(7))

        switch ctx.mode {
        case .json:
            ctx.writeJSON(ForecastJSON(place: place, report: report, hours: hours, days: days, stale: fetched.isStale))
        case .plain:
            var lines = ["Forecast for \(place.name) (Open-Meteo)."]
            for hour in hours {
                lines.append("\(fmt.hour(hour.time)): \(fmt.temperature(hour.temperature, unit: true)), \(WeatherCondition.description(hour.weatherCode).lowercased()), \(fmt.percent(hour.precipitationProbability)) chance of rain, wind \(fmt.wind(speed: hour.windSpeed, gust: nil, direction: hour.windDirection)).")
            }
            lines.append(contentsOf: DayRows.plain(days, fmt: fmt))
            ctx.write(lines)
        case .pretty:
            ctx.write(pretty(place: place, report: report, hours: hours, days: days, fetched: fetched, fmt: fmt, ctx: ctx, width: width))
        }
        return fetched.isStale ? .unavailable : .ok
    }

    static func temperatureColor(_ value: Double, units: UnitSystem) -> RGB {
        let f = units == .imperial ? value : value * 9 / 5 + 32
        switch f {
        case ..<40: return Theme.information.mixed(with: RGB(hex: 0xBFD9FF), amount: 0.5)
        case ..<65: return Theme.information
        case ..<80: return Theme.lamp
        case ..<92: return Theme.warning
        default: return Theme.lightning[2]
        }
    }

    static func rainColor(_ probability: Double) -> RGB {
        probability >= 60 ? Theme.lightning[2] : probability >= 30 ? Theme.lightning[1] : Theme.rain
    }

    static func pretty(place: Place, report: WeatherReport, hours: [WeatherReport.Hour], days: [WeatherReport.Day],
                       fetched: Fetched<WeatherReport>, fmt: Formatter, ctx: Context, width: Int) -> [String] {
        let s = ctx.styler
        let column = 5
        let label = { (text: String) in "  " + s.paint(TextWidth.pad(text, to: 10), Theme.mist) }
        var lines = [""]
        let issued = fetched.storedAt.map { "OPEN-METEO · " + (fetched.isStale ? "stale, " : "") + "updated " + Formatter.ago($0, now: ctx.now) } ?? "OPEN-METEO"
        lines.append(TextWidth.spread("  " + s.paint("FORECAST", Theme.porcelain, bold: true) + s.paint("  ·  ", Theme.faint) + place.name,
                                      s.paint(issued, fetched.isStale ? Theme.advisory : Theme.faint), width: width))
        lines.append("")
        lines.append("  " + s.bold("NEXT \(hours.count) HOURS"))

        lines.append(label("") + hours.map { s.paint(TextWidth.pad(fmt.hour($0.time), to: column), Theme.mist) }.joined())
        lines.append(label("") + hours.map { TextWidth.pad(ctx.icon($0.weatherCode, isDay: $0.isDay), to: column) }.joined())
        lines.append(label("Temp \(ctx.units.temperatureSymbol)") + hours.map {
            s.paint(TextWidth.pad(fmt.temperature($0.temperature).replacingOccurrences(of: "°", with: ""), to: column), $0.temperature.map { temperatureColor($0, units: ctx.units) } ?? Theme.faint, bold: true)
        }.joined())
        let temps = hours.compactMap(\.temperature)
        let low = (temps.min() ?? 0) - 1, high = (temps.max() ?? 1) + 1
        lines.append(label("") + hours.map { hour -> String in
            guard let t = hour.temperature else { return String(repeating: " ", count: column) }
            let block = String(repeating: String(Charts.block((t - low) / (high - low), minimum: true)), count: 3)
            return s.paint(block, temperatureColor(t, units: ctx.units)) + "  "
        }.joined())
        lines.append(label("Rain %") + hours.map { hour -> String in
            let p = hour.precipitationProbability ?? 0
            return s.paint(TextWidth.pad(String(Int(p)), to: column), rainColor(p))
        }.joined())
        lines.append(label("") + hours.map { hour -> String in
            let p = hour.precipitationProbability ?? 0
            return s.paint(String(repeating: String(Charts.block(p / 100, minimum: true)), count: 3), rainColor(p)) + "  "
        }.joined())
        lines.append(label("Wind \(ctx.units.windUnit)") + hours.map { hour -> String in
            let dir = hour.windDirection.map { Compass.octant($0) } ?? ""
            let speed = hour.windSpeed.map { String(Int($0.rounded())) } ?? "-"
            return s.paint(TextWidth.pad(dir + speed, to: column), Theme.mist)
        }.joined())
        lines.append("")

        lines.append("  " + s.bold("NEXT 7 DAYS") + s.paint("   low · high · chance of rain", Theme.faint))
        lines.append(contentsOf: DayRows.lines(days, fmt: fmt, ctx: ctx, barWidth: 28))
        if let today = days.first, let sunrise = today.sunrise, let sunset = today.sunset {
            lines.append("")
            lines.append("  " + s.paint("Sunrise \(fmt.time(sunrise)) · sunset \(fmt.time(sunset))", Theme.faint)
                         + s.paint(" · moon \(LunarPhase(at: ctx.now).name.displayName.lowercased())", Theme.faint))
        }
        lines.append("")
        return lines
    }
}

struct ForecastJSON: Encodable {
    struct Hour: Encodable {
        let time: Date
        let temperature: Double?
        let feelsLike: Double?
        let precipitationProbability: Double?
        let precipitation: Double?
        let condition: String
        let windSpeed: Double?
        let windDirection: Double?
    }
    struct Day: Encodable {
        let date: String
        let high: Double?
        let low: Double?
        let condition: String
        let precipitationProbability: Double?
        let precipitation: Double?
        let uvIndex: Double?
        let sunrise: Date?
        let sunset: Date?
    }
    let schema = "dreadcast.forecast/1"
    let location: LocationJSON
    let source = "open-meteo"
    let units: String
    let fetchedAt: Date
    let stale: Bool
    let hours: [Hour]
    let days: [Day]

    init(place: Place, report: WeatherReport, hours: [WeatherReport.Hour], days: [WeatherReport.Day], stale: Bool) {
        location = LocationJSON(place)
        units = report.units.rawValue
        fetchedAt = report.fetchedAt
        self.stale = stale
        self.hours = hours.map {
            Hour(time: $0.time, temperature: $0.temperature, feelsLike: $0.apparentTemperature,
                 precipitationProbability: $0.precipitationProbability, precipitation: $0.precipitation,
                 condition: WeatherCondition.description($0.weatherCode), windSpeed: $0.windSpeed, windDirection: $0.windDirection)
        }
        self.days = Self.days(days, timeZone: report.timeZone)
    }

    static func days(_ days: [WeatherReport.Day], timeZone: TimeZone) -> [Day] {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"
        return days.map {
            Day(date: dateFormatter.string(from: $0.date), high: $0.high, low: $0.low,
                condition: WeatherCondition.description($0.weatherCode), precipitationProbability: $0.precipitationProbability,
                precipitation: $0.precipitation, uvIndex: $0.uvIndex, sunrise: $0.sunrise, sunset: $0.sunset)
        }
    }
}
