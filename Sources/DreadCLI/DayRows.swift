import Foundation
import DreadcastKit
import DreadTerminal

/// Daily forecast rows: day, icon, low, a range bar on a shared scale, high, chance of
/// rain and conditions. Shared by `dread` and `dread forecast`.
enum DayRows {
    static func lines(_ days: [WeatherReport.Day], fmt: Formatter, ctx: Context, barWidth span: Int) -> [String] {
        let s = ctx.styler
        let lows = days.compactMap(\.low), highs = days.compactMap(\.high)
        let scaleLow = (lows.min() ?? 0).rounded(.down) - 1
        let scaleHigh = (highs.max() ?? 1).rounded(.up) + 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = fmt.timeZone
        return days.map { day in
            var bar = ""
            for i in 0..<span {
                let t = scaleLow + (Double(i) + 0.5) / Double(span) * (scaleHigh - scaleLow)
                let inside = (day.low ?? .infinity) <= t && t <= (day.high ?? -.infinity)
                bar += inside ? s.paint("━", ForecastCommand.temperatureColor(t, units: ctx.units)) : s.paint("─", Theme.faint)
            }
            let p = day.precipitationProbability ?? 0
            let name = calendar.isDate(day.date, inSameDayAs: ctx.now) ? "Today" : fmt.weekday(day.date)
            return "  " + TextWidth.pad(name, to: 6) + TextWidth.pad(ctx.icon(day.weatherCode), to: 3)
                + s.paint(TextWidth.pad(fmt.temperature(day.low), to: 5, align: .right), Theme.information) + " " + bar + " "
                + s.paint(TextWidth.pad(fmt.temperature(day.high), to: 5), Theme.warning)
                + s.paint(TextWidth.pad("\(Int(p))%", to: 5, align: .right), ForecastCommand.rainColor(p)) + "  "
                + s.paint(WeatherCondition.description(day.weatherCode), Theme.mist)
        }
    }

    /// Plain sentences for the same days.
    static func plain(_ days: [WeatherReport.Day], fmt: Formatter) -> [String] {
        days.map { day in
            "\(fmt.weekday(day.date, short: false)): high \(fmt.temperature(day.high)), low \(fmt.temperature(day.low)), \(WeatherCondition.description(day.weatherCode).lowercased()), \(fmt.percent(day.precipitationProbability)) chance of rain."
        }
    }

    /// Days from today on, in the report's own time zone.
    static func upcoming(_ report: WeatherReport, from now: Date, count: Int) -> [WeatherReport.Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = report.timeZone
        let today = calendar.startOfDay(for: now)
        return Array(report.daily.filter { $0.date >= today }.prefix(count))
    }
}
