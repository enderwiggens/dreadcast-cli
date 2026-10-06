import Foundation
import DreadcastKit

/// Dreadcast's dry lines. The rules are the brand's: at most one line, never in
/// alerts, errors, plain or JSON output, and never while any alert is active.
public enum Quip {
    public static func line(report: WeatherReport, alertsActive: Bool, now: Date) -> String? {
        guard !alertsActive else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = report.timeZone
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)
        let code = report.current.weatherCode
        let isWeekday = (2...6).contains(weekday)

        if WeatherCondition.isThunderstorm(code) { return "A good day to have an inside." }
        if (71...86).contains(code ?? -1) { return "The great indoors awaits." }
        if WeatherCondition.isPrecipitation(code) { return "At least you’ll know what to wear." }
        if code == 45 || code == 48 { return "Outdoor plans under review." }
        if isWeekday && (6..<10).contains(hour) { return "Your 9 AM remains scheduled." }
        if let t = report.current.temperature, report.current.isDay,
           (report.units == .imperial ? t >= 92 : t >= 33) {
            return "The sun is expressing itself."
        }
        if !report.current.isDay && WeatherCondition.isClear(code) { return "Comfortingly uneventful." }
        if weekday == 3 { return "Another ordinary Tuesday." }
        let rotation = [
            "There’s a lot in the forecast.",
            "A chance of rain. Among other things.",
            "The outlook could be better.",
            "Within expected parameters.",
            "Still expected at standup."
        ]
        let day = calendar.ordinality(of: .day, in: .year, for: now) ?? 0
        return rotation[day % rotation.count]
    }

    /// Outlook commentary is labeled and never changes a reading.
    public static func outlook(kp: Double?) -> String {
        guard let kp else { return "The sky is keeping its own counsel." }
        switch kp {
        case 7...: return "The sun is expressing itself, forcefully."
        case 5..<7: return "The sun is expressing itself."
        case 4..<5: return "The sun is expressing itself, modestly."
        default: return "The sun has nothing further to add."
        }
    }
}
