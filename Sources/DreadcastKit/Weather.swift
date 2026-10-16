import Foundation

public enum UnitSystem: String, Codable, Sendable, CaseIterable {
    case imperial, metric

    var temperatureParameter: String { self == .imperial ? "fahrenheit" : "celsius" }
    var windParameter: String { self == .imperial ? "mph" : "kmh" }
    var precipitationParameter: String { self == .imperial ? "inch" : "mm" }

    public var temperatureSymbol: String { self == .imperial ? "°F" : "°C" }
    public var windUnit: String { self == .imperial ? "mph" : "km/h" }
    public var precipitationUnit: String { self == .imperial ? "in" : "mm" }
    public var distanceUnit: String { self == .imperial ? "mi" : "km" }

    public func distance(miles: Double) -> Double { self == .imperial ? miles : miles * 1.609344 }
    public func speed(mph: Double) -> Double { self == .imperial ? mph : mph * 1.609344 }
}

/// Current conditions plus 15-minute, hourly and daily forecasts from the Dreadcast
/// API, which gets them from Open-Meteo.
public struct WeatherReport: Codable, Sendable {
    public struct Current: Codable, Sendable {
        public var time: Date
        public var temperature: Double?
        public var apparentTemperature: Double?
        public var humidity: Double?
        public var dewPoint: Double?
        public var weatherCode: Int?
        public var windSpeed: Double?
        public var windDirection: Double?
        public var windGusts: Double?
        public var isDay: Bool
        public var precipitation: Double?
        public var pressure: Double?
        public var cloudCover: Double?
    }

    public struct Minutely: Codable, Sendable {
        public var time: Date
        /// Accumulation over the 15-minute step, in the report's precipitation unit.
        public var precipitation: Double?
        public var weatherCode: Int?
    }

    public struct Hour: Codable, Sendable {
        public var time: Date
        public var temperature: Double?
        public var apparentTemperature: Double?
        public var precipitationProbability: Double?
        public var precipitation: Double?
        public var weatherCode: Int?
        public var isDay: Bool
        public var windSpeed: Double?
        public var windDirection: Double?
        public var cloudCover: Double?
        public var pressure: Double?
        public var dewPoint: Double?
        public var cape: Double?
    }

    public struct Day: Codable, Sendable {
        /// Local midnight of the forecast day.
        public var date: Date
        public var high: Double?
        public var low: Double?
        public var apparentHigh: Double?
        public var apparentLow: Double?
        public var weatherCode: Int?
        public var precipitationProbability: Double?
        public var precipitation: Double?
        public var windSpeed: Double?
        public var windGusts: Double?
        public var uvIndex: Double?
        public var sunrise: Date?
        public var sunset: Date?
    }

    public var fetchedAt: Date
    public var coordinate: GeoCoordinate
    public var units: UnitSystem
    public var timeZoneIdentifier: String
    /// The provider's UTC offset, used when the system has no time zone database.
    public var utcOffsetSeconds: Int? = nil
    public var current: Current
    public var minutely: [Minutely]
    public var hourly: [Hour]
    public var daily: [Day]
    /// The API couldn't reach the provider and served an older reading.
    public var stale: Bool? = nil

    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier)
            ?? utcOffsetSeconds.flatMap(TimeZone.init(secondsFromGMT:))
            ?? .current
    }

    public func hours(from now: Date, count: Int) -> [Hour] {
        Array(hourly.filter { $0.time > now.addingTimeInterval(-3600) }.prefix(max(0, count)))
    }

    public func day(containing date: Date) -> Day? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return daily.first { calendar.isDate($0.date, inSameDayAs: date) }
    }

    /// The lowest hourly temperature from now until 9 AM tomorrow, local time.
    public func overnightLow(after now: Date) -> Double? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
              let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) else { return nil }
        return hourly.filter { $0.time >= now && $0.time <= morning }.compactMap(\.temperature).min()
    }

    /// Change in sea-level pressure over roughly the last three hours, in hPa.
    public func pressureTendency(at now: Date) -> Double? {
        guard let latest = hourly.last(where: { $0.time <= now && $0.pressure != nil }),
              let earlier = hourly.last(where: { $0.time <= latest.time.addingTimeInterval(-3 * 3600) && $0.pressure != nil }),
              let a = latest.pressure, let b = earlier.pressure else { return nil }
        return a - b
    }

    /// The current hour's convective available potential energy, J/kg.
    public func cape(at now: Date) -> Double? {
        hourly.last(where: { $0.time <= now.addingTimeInterval(1800) && $0.cape != nil })?.cape
    }
}

/// Weather from the Dreadcast API: current conditions, with 15-minute steps, from
/// `/v1/weather/current`, and the hourly and daily forecast from `/v1/weather/forecast`.
/// The API converts units, so each answer arrives in the units asked for.
public struct WeatherService: Sendable {
    private let http: HTTPClient
    private let api: URL

    public init(http: HTTPClient = HTTPClient(), api: URL) {
        self.http = http
        self.api = api
    }

    /// The request for `path` at the rounded coordinate, in `units`.
    static func url(_ api: URL, _ path: String, coordinate: GeoCoordinate, units: UnitSystem) -> URL? {
        DreadcastAPI.url(api, path, DreadcastAPI.coordinate(coordinate) + [
            URLQueryItem(name: "temperature_unit", value: units.temperatureParameter),
            URLQueryItem(name: "wind_speed_unit", value: units.windParameter),
            URLQueryItem(name: "precipitation_unit", value: units.precipitationParameter)
        ])
    }

    public func report(at coordinate: GeoCoordinate, units: UnitSystem, now: Date = Date()) async throws -> WeatherReport {
        let http = self.http
        async let current = DreadcastAPI.data(http, Self.url(api, "v1/weather/current", coordinate: coordinate, units: units),
                                              what: "Weather", maximumBytes: 256 * 1024)
        async let forecast = DreadcastAPI.data(http, Self.url(api, "v1/weather/forecast", coordinate: coordinate, units: units),
                                               what: "The forecast", maximumBytes: 2 * 1024 * 1024)
        return try Self.decode(current: try await current, forecast: try await forecast,
                               coordinate: coordinate.coarsened, units: units, now: now)
    }

    struct Units: Decodable {
        let temperature: String
        let windSpeed: String
        let precipitation: String
    }

    struct CurrentAnswer: Decodable {
        struct Current: Decodable {
            let time: String
            let temperature: Double?
            let apparentTemperature: Double?
            let relativeHumidity: Double?
            let weatherCode: Double?
            let isDay: Bool?
            let windSpeed: Double?
            let windDirection: Double?
            let windGusts: Double?
            let precipitation: Double?
            let cloudCover: Double?
            let dewPoint: Double?
            let pressure: Double?
        }
        struct Step: Decodable {
            let time: String
            let precipitation: Double?
            let weatherCode: Double?
        }
        let location: DreadcastAPI.Location
        let current: Current
        let minutely15: [Step]?
        let units: Units
        let source: DreadcastAPI.Source?
    }

    struct ForecastAnswer: Decodable {
        struct Hour: Decodable {
            let time: String
            let temperature: Double?
            let apparentTemperature: Double?
            let precipitationProbability: Double?
            let precipitation: Double?
            let weatherCode: Double?
            let isDay: Bool?
            let windSpeed: Double?
            let windDirection: Double?
            let cloudCover: Double?
            let pressure: Double?
            let dewPoint: Double?
            let cape: Double?
        }
        struct Day: Decodable {
            let date: String
            let weatherCode: Double?
            let temperatureMax: Double?
            let temperatureMin: Double?
            let apparentTemperatureMax: Double?
            let apparentTemperatureMin: Double?
            let precipitationProbabilityMax: Double?
            let precipitationSum: Double?
            let windSpeedMax: Double?
            let windGustsMax: Double?
            let uvIndexMax: Double?
            let sunrise: String?
            let sunset: String?
        }
        let location: DreadcastAPI.Location
        let hourly: [Hour]
        let daily: [Day]
        let units: Units
        let source: DreadcastAPI.Source?
    }

    /// Both answers as one report. Values that can't be right become nil; anything that
    /// leaves the report unreadable, or in other units than asked for, fails it.
    public static func decode(current currentData: Data, forecast forecastData: Data, coordinate: GeoCoordinate,
                              units: UnitSystem, now: Date) throws -> WeatherReport {
        let currentAnswer = try DreadcastAPI.decode(CurrentAnswer.self, from: currentData)
        let forecastAnswer = try DreadcastAPI.decode(ForecastAnswer.self, from: forecastData)
        for answer in [currentAnswer.units, forecastAnswer.units] {
            guard answer.temperature == units.temperatureParameter, answer.windSpeed == units.windParameter,
                  answer.precipitation == units.precipitationParameter else { throw DreadcastError.invalidResponse(DreadcastAPI.source) }
        }
        let location = forecastAnswer.location
        let identifier = location.timeZoneIdentifier ?? currentAnswer.location.timeZoneIdentifier
        // Minimal Linux systems may lack a time zone database; fall back to the fixed offset.
        let zone = identifier.flatMap(TimeZone.init(identifier:))
            ?? location.offset.flatMap(TimeZone.init(secondsFromGMT:))
            ?? TimeZone(secondsFromGMT: 0)!

        let c = currentAnswer.current
        guard let currentTime = ISODate.parse(c.time) else { throw DreadcastError.invalidResponse(DreadcastAPI.source) }
        let current = WeatherReport.Current(
            time: currentTime,
            temperature: finite(c.temperature),
            apparentTemperature: finite(c.apparentTemperature),
            humidity: percent(c.relativeHumidity),
            dewPoint: finite(c.dewPoint),
            weatherCode: code(c.weatherCode),
            windSpeed: nonnegative(c.windSpeed),
            windDirection: finite(c.windDirection),
            windGusts: nonnegative(c.windGusts),
            isDay: c.isDay ?? true,
            precipitation: nonnegative(c.precipitation),
            pressure: finite(c.pressure),
            cloudCover: percent(c.cloudCover)
        )

        let minutely = try (currentAnswer.minutely15 ?? []).map { step -> WeatherReport.Minutely in
            guard let time = ISODate.parse(step.time) else { throw DreadcastError.invalidResponse(DreadcastAPI.source) }
            return WeatherReport.Minutely(time: time, precipitation: nonnegative(step.precipitation), weatherCode: code(step.weatherCode))
        }
        let hourly = try forecastAnswer.hourly.map { hour -> WeatherReport.Hour in
            guard let time = ISODate.parse(hour.time) else { throw DreadcastError.invalidResponse(DreadcastAPI.source) }
            return WeatherReport.Hour(
                time: time,
                temperature: finite(hour.temperature),
                apparentTemperature: finite(hour.apparentTemperature),
                precipitationProbability: percent(hour.precipitationProbability),
                precipitation: nonnegative(hour.precipitation),
                weatherCode: code(hour.weatherCode),
                isDay: hour.isDay ?? true,
                windSpeed: nonnegative(hour.windSpeed),
                windDirection: finite(hour.windDirection),
                cloudCover: percent(hour.cloudCover),
                pressure: finite(hour.pressure),
                dewPoint: finite(hour.dewPoint),
                cape: nonnegative(hour.cape)
            )
        }
        // Daily rows name local calendar dates: each becomes local midnight there.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let daily = try forecastAnswer.daily.map { day -> WeatherReport.Day in
            let parts = day.date.split(separator: "-").compactMap { Int($0) }
            guard day.date.count == 10, parts.count == 3,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
                throw DreadcastError.invalidResponse(DreadcastAPI.source)
            }
            return WeatherReport.Day(
                date: date,
                high: finite(day.temperatureMax), low: finite(day.temperatureMin),
                apparentHigh: finite(day.apparentTemperatureMax), apparentLow: finite(day.apparentTemperatureMin),
                weatherCode: code(day.weatherCode),
                precipitationProbability: percent(day.precipitationProbabilityMax),
                precipitation: nonnegative(day.precipitationSum),
                windSpeed: nonnegative(day.windSpeedMax),
                windGusts: nonnegative(day.windGustsMax),
                uvIndex: nonnegative(day.uvIndexMax),
                sunrise: ISODate.parse(day.sunrise),
                sunset: ISODate.parse(day.sunset)
            )
        }
        for times in [minutely.map(\.time), hourly.map(\.time), daily.map(\.date)] {
            guard zip(times, times.dropFirst()).allSatisfy({ $0.0 < $0.1 }) else { throw DreadcastError.invalidResponse(DreadcastAPI.source) }
        }
        guard hourly.count <= 24 * 17, daily.count <= 16, minutely.count <= 4 * 24 else {
            throw DreadcastError.invalidResponse(DreadcastAPI.source)
        }

        // The forecast's fetch time, never later than now.
        let fetched = ISODate.parse(forecastAnswer.source?.fetchedAt).map { min($0, now) } ?? now
        let stale = currentAnswer.source?.stale == true || forecastAnswer.source?.stale == true
        return WeatherReport(fetchedAt: fetched, coordinate: coordinate, units: units,
                             timeZoneIdentifier: identifier ?? zone.identifier, utcOffsetSeconds: location.offset,
                             current: current, minutely: minutely, hourly: hourly, daily: daily, stale: stale ? true : nil)
    }

    static func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
    static func nonnegative(_ value: Double?) -> Double? { finite(value).flatMap { $0 >= 0 ? $0 : nil } }
    static func percent(_ value: Double?) -> Double? { finite(value).flatMap { (0...100).contains($0) ? $0 : nil } }
    static func code(_ value: Double?) -> Int? { finite(value).flatMap { (0...99).contains($0) ? Int($0) : nil } }
}

/// Current US AQI and its pollutants at one point: CAMS model values from the Dreadcast
/// API's `/v1/air/current`, which gets them from Open-Meteo.
public struct AirQualityReading: Codable, Sendable {
    public var fetchedAt: Date
    public var time: Date
    public var usAQI: Int
    public var pm2_5: Double?
    public var pm10: Double?
    public var ozone: Double?
    public var dust: Double?

    public var category: String {
        switch usAQI {
        case ...50: return "Good"
        case 51...100: return "Moderate"
        case 101...150: return "Unhealthy for sensitive groups"
        case 151...200: return "Unhealthy"
        case 201...300: return "Very unhealthy"
        default: return "Hazardous"
        }
    }
}

public struct AirQualityService: Sendable {
    private let http: HTTPClient
    private let api: URL

    public init(http: HTTPClient = HTTPClient(), api: URL) {
        self.http = http
        self.api = api
    }

    public func reading(at coordinate: GeoCoordinate, now: Date = Date()) async throws -> AirQualityReading {
        try Self.decode(try await answer(at: coordinate), now: now)
    }

    /// Modeled dust at the place, µg/m³, and the hour it describes; it needs no AQI.
    public func dust(at coordinate: GeoCoordinate, now: Date = Date()) async throws -> (value: Double?, time: Date) {
        let current = try Self.current(try await answer(at: coordinate), now: now)
        return (WeatherService.nonnegative(current.dust), current.time)
    }

    private func answer(at coordinate: GeoCoordinate) async throws -> Data {
        let url = DreadcastAPI.url(api, "v1/air/current", DreadcastAPI.coordinate(coordinate))
        return try await DreadcastAPI.data(http, url, what: "Air quality", maximumBytes: 64 * 1024)
    }

    struct Answer: Decodable {
        struct Current: Decodable {
            let time: String
            let usAqi: Double?
            let pm25: Double?
            let pm10: Double?
            let ozone: Double?
            let dust: Double?
        }
        let current: Current
    }

    /// The answer's values, with the hour they describe, which can't be hours ahead.
    static func current(_ data: Data, now: Date) throws -> (time: Date, usAqi: Double?, pm25: Double?, pm10: Double?, ozone: Double?, dust: Double?) {
        let current = try DreadcastAPI.decode(Answer.self, from: data).current
        guard let time = ISODate.parse(current.time), time.timeIntervalSince(now) < 2 * 3600 else {
            throw DreadcastError.invalidResponse(DreadcastAPI.source)
        }
        return (time, current.usAqi, current.pm25, current.pm10, current.ozone, current.dust)
    }

    public static func decode(_ data: Data, now: Date) throws -> AirQualityReading {
        let current = try Self.current(data, now: now)
        guard let aqi = WeatherService.nonnegative(current.usAqi), aqi <= 1000 else {
            throw DreadcastError.unavailable("Air quality is unavailable for this location.")
        }
        return AirQualityReading(fetchedAt: now, time: current.time, usAQI: Int(aqi.rounded()),
                                 pm2_5: WeatherService.nonnegative(current.pm25), pm10: WeatherService.nonnegative(current.pm10),
                                 ozone: WeatherService.nonnegative(current.ozone), dust: WeatherService.nonnegative(current.dust))
    }
}
