import Foundation
import DreadcastKit

/// Formatting helpers. Times use the forecast location's time zone.
public struct Formatter: Sendable {
    public let units: UnitSystem
    public let timeZone: TimeZone

    public init(units: UnitSystem, timeZone: TimeZone) {
        self.units = units
        self.timeZone = timeZone
    }

    public func temperature(_ value: Double?, unit: Bool = false) -> String {
        guard let value else { return "--" }
        let rounded = Int(value.rounded())
        return unit ? "\(rounded)\(units.temperatureSymbol)" : "\(rounded)°"
    }

    public func percent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
    }

    public func wind(speed: Double?, gust: Double?, direction: Double?) -> String {
        guard let speed else { return "--" }
        let dir = direction.map { Compass.point($0) + " " } ?? ""
        let s = Int(speed.rounded())
        if s == 0 { return "Calm" }
        if let gust, gust >= speed + 9 {
            return "\(dir)\(s) G \(Int(gust.rounded())) \(units.windUnit)"
        }
        return "\(dir)\(s) \(units.windUnit)"
    }

    public func distance(miles: Double, decimals: Bool = false) -> String {
        let value = units.distance(miles: miles)
        if decimals && value < 10 {
            return String(format: "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), value, units.distanceUnit)
        }
        return "\(grouped(Int(value.rounded()))) \(units.distanceUnit)"
    }

    public func speed(mph: Double) -> String {
        "\(Int(units.speed(mph: mph).rounded())) \(units.windUnit)"
    }

    public func precipitation(_ value: Double?) -> String {
        guard let value else { return "--" }
        if units == .imperial { return String(format: "%.2f in", locale: Locale(identifier: "en_US_POSIX"), value) }
        return String(format: "%.1f mm", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// "3p", "12a": compact hour labels for charts.
    public func hour(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let h = calendar.component(.hour, from: date)
        let twelve = h % 12 == 0 ? 12 : h % 12
        return "\(twelve)\(h < 12 ? "a" : "p")"
    }

    public func weekday(_ date: Date, short: Bool = true) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = short ? "EEE" : "EEEE"
        return f.string(from: date)
    }

    public func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE MMM d"
        return f.string(from: date)
    }

    /// "until 3:15 PM", "until Tue 6:00 AM" for times on another day.
    public func until(_ date: Date, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if calendar.isDate(date, inSameDayAs: now) { return time(date) }
        return weekday(date) + " " + time(date)
    }

    public func zoneAbbreviation(_ date: Date) -> String {
        timeZone.abbreviation(for: date) ?? ""
    }

    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<45: return "just now"
        case ..<3600: return "\(Int((seconds / 60).rounded(.up))) min ago"
        case ..<86400:
            let hours = Int(seconds / 3600)
            return "\(hours) h ago"
        default:
            return "\(Int(seconds / 86400)) d ago"
        }
    }

    public static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    public func grouped(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }
}
