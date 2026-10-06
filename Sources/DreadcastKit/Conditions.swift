import Foundation

/// WMO weather interpretation codes used by Open-Meteo.
public enum WeatherCondition {
    public static func description(_ code: Int?) -> String {
        guard let code else { return "Unavailable" }
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51, 53, 55: return "Drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80: return "Rain showers"
        case 81: return "Heavy showers"
        case 82: return "Very heavy showers"
        case 85, 86: return "Snow showers"
        case 95: return "Thunderstorm"
        case 96, 99: return "Thunderstorm with hail"
        default: return "Mixed conditions"
        }
    }

    /// A terminal glyph. Emoji take two cells; the ASCII form fits any font.
    public static func emoji(_ code: Int?, isDay: Bool = true) -> String {
        guard let code else { return "☁️" }
        switch code {
        case 0: return isDay ? "☀️" : "🌙"
        case 1: return isDay ? "🌤️" : "🌙"
        case 2: return isDay ? "⛅" : "☁️"
        case 3: return "☁️"
        case 45, 48: return "🌫️"
        case 51...57: return "🌦️"
        case 61...67, 80...82: return "🌧️"
        case 71...77, 85, 86: return "🌨️"
        case 95...99: return "⛈️"
        default: return "☁️"
        }
    }

    public static func ascii(_ code: Int?, isDay: Bool = true) -> String {
        guard let code else { return "--" }
        switch code {
        case 0: return isDay ? "()" : "C "
        case 1, 2: return isDay ? "(~" : "C~"
        case 3: return "~~"
        case 45, 48: return "=="
        case 51...57: return "' "
        case 61...67, 80...82: return "''"
        case 71...77, 85, 86: return "**"
        case 95...99: return "/!"
        default: return "~~"
        }
    }

    public static func isThunderstorm(_ code: Int?) -> Bool { (95...99).contains(code ?? -1) }
    public static func isPrecipitation(_ code: Int?) -> Bool {
        guard let code else { return false }
        return (51...99).contains(code) && !(code == 45 || code == 48)
    }
    public static func isClear(_ code: Int?) -> Bool { (0...1).contains(code ?? -1) }
}
