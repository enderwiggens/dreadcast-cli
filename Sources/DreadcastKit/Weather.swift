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

/// Current conditions plus 15-minute, hourly and daily forecasts from Open-Meteo.
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

public struct WeatherService: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public static func requestURL(for coordinate: GeoCoordinate, units: UnitSystem) -> URL {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        let c = coordinate.coarsened
        components.queryItems = [
            .init(name: "latitude", value: String(c.latitude)),
            .init(name: "longitude", value: String(c.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,dew_point_2m,weather_code,wind_speed_10m,wind_direction_10m,wind_gusts_10m,is_day,precipitation,pressure_msl,cloud_cover"),
            .init(name: "minutely_15", value: "precipitation,weather_code"),
            .init(name: "forecast_minutely_15", value: "12"),
            .init(name: "hourly", value: "temperature_2m,apparent_temperature,precipitation_probability,precipitation,weather_code,is_day,wind_speed_10m,wind_direction_10m,cloud_cover,pressure_msl,dew_point_2m,cape"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,apparent_temperature_max,apparent_temperature_min,precipitation_probability_max,precipitation_sum,wind_speed_10m_max,wind_gusts_10m_max,uv_index_max,sunrise,sunset"),
            .init(name: "past_hours", value: "6"),
            .init(name: "forecast_hours", value: "168"),
            .init(name: "forecast_days", value: "7"),
            .init(name: "temperature_unit", value: units.temperatureParameter),
            .init(name: "wind_speed_unit", value: units.windParameter),
            .init(name: "precipitation_unit", value: units.precipitationParameter),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime")
        ]
        return components.url!
    }

    public func report(at coordinate: GeoCoordinate, units: UnitSystem, now: Date = Date()) async throws -> WeatherReport {
        let url = Self.requestURL(for: coordinate, units: units)
        let data = try await http.data(url, accept: "application/json", timeout: 20, maximumBytes: 4 * 1024 * 1024, source: "Open-Meteo")
        return try Self.decode(data, coordinate: coordinate.coarsened, units: units, fetchedAt: now)
    }

    public static func decode(_ data: Data, coordinate: GeoCoordinate, units: UnitSystem, fetchedAt: Date) throws -> WeatherReport {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw DreadcastError.invalidResponse("Open-Meteo")
        }
        guard let current = payload.current, let currentTime = current.number("time") else {
            throw DreadcastError.invalidResponse("Open-Meteo")
        }
        // Minimal Linux systems may lack a time zone database; fall back to the fixed offset.
        let zone = TimeZone(identifier: payload.timezone)
            ?? payload.utc_offset_seconds.flatMap(TimeZone.init(secondsFromGMT:))
            ?? TimeZone(secondsFromGMT: 0)!
        try payload.hourly?.validate()
        try payload.daily?.validate()
        try payload.minutely_15?.validate()

        let report = WeatherReport.Current(
            time: Date(timeIntervalSince1970: currentTime),
            temperature: current.number("temperature_2m"),
            apparentTemperature: current.number("apparent_temperature"),
            humidity: current.number("relative_humidity_2m").flatMap { (0...100).contains($0) ? $0 : nil },
            dewPoint: current.number("dew_point_2m"),
            weatherCode: current.number("weather_code").flatMap { (0...99).contains($0) ? Int($0) : nil },
            windSpeed: current.number("wind_speed_10m").flatMap { $0 >= 0 ? $0 : nil },
            windDirection: current.number("wind_direction_10m"),
            windGusts: current.number("wind_gusts_10m").flatMap { $0 >= 0 ? $0 : nil },
            isDay: (current.number("is_day") ?? 1) != 0,
            precipitation: current.number("precipitation").flatMap { $0 >= 0 ? $0 : nil },
            pressure: current.number("pressure_msl"),
            cloudCover: current.number("cloud_cover")
        )

        var minutely: [WeatherReport.Minutely] = []
        if let m = payload.minutely_15 {
            minutely = m.time.indices.map { i in
                WeatherReport.Minutely(time: Date(timeIntervalSince1970: m.time[i]),
                                       precipitation: m.nonnegative("precipitation", i),
                                       weatherCode: m.code(i))
            }
        }

        var hourly: [WeatherReport.Hour] = []
        if let h = payload.hourly {
            hourly = h.time.indices.map { i in
                WeatherReport.Hour(
                    time: Date(timeIntervalSince1970: h.time[i]),
                    temperature: h.number("temperature_2m", i),
                    apparentTemperature: h.number("apparent_temperature", i),
                    precipitationProbability: h.probability("precipitation_probability", i),
                    precipitation: h.nonnegative("precipitation", i),
                    weatherCode: h.code(i),
                    isDay: (h.number("is_day", i) ?? 1) != 0,
                    windSpeed: h.nonnegative("wind_speed_10m", i),
                    windDirection: h.number("wind_direction_10m", i),
                    cloudCover: h.probability("cloud_cover", i),
                    pressure: h.number("pressure_msl", i),
                    dewPoint: h.number("dew_point_2m", i),
                    cape: h.nonnegative("cape", i)
                )
            }
        }

        var daily: [WeatherReport.Day] = []
        if let d = payload.daily, !d.time.isEmpty {
            // Daily values name calendar dates. Use the provider offset so a DST change
            // can't turn the next day's midnight into yesterday at 23:00.
            let offset = payload.utc_offset_seconds ?? zone.secondsFromGMT(for: Date(timeIntervalSince1970: d.time[0]))
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(secondsFromGMT: 0)!
            var local = Calendar(identifier: .gregorian)
            local.timeZone = zone
            func calendarDay(_ timestamp: Double) -> Date {
                let noon = Date(timeIntervalSince1970: timestamp + Double(offset) + 43200)
                let parts = utc.dateComponents([.year, .month, .day], from: noon)
                return local.date(from: parts) ?? Date(timeIntervalSince1970: timestamp)
            }
            daily = d.time.indices.map { i in
                WeatherReport.Day(
                    date: calendarDay(d.time[i]),
                    high: d.number("temperature_2m_max", i), low: d.number("temperature_2m_min", i),
                    apparentHigh: d.number("apparent_temperature_max", i), apparentLow: d.number("apparent_temperature_min", i),
                    weatherCode: d.code(i),
                    precipitationProbability: d.probability("precipitation_probability_max", i),
                    precipitation: d.nonnegative("precipitation_sum", i),
                    windSpeed: d.nonnegative("wind_speed_10m_max", i),
                    windGusts: d.nonnegative("wind_gusts_10m_max", i),
                    uvIndex: d.nonnegative("uv_index_max", i),
                    sunrise: d.number("sunrise", i).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                    sunset: d.number("sunset", i).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
                )
            }
        }

        return WeatherReport(fetchedAt: fetchedAt, coordinate: coordinate, units: units,
                             timeZoneIdentifier: payload.timezone, utcOffsetSeconds: payload.utc_offset_seconds,
                             current: report, minutely: minutely, hourly: hourly, daily: daily)
    }

    private struct Payload: Decodable {
        let timezone: String
        let utc_offset_seconds: Int?
        let current: CurrentValues?
        let minutely_15: Series?
        let hourly: Series?
        let daily: Series?
    }

    /// Current values arrive as a flat object of numbers.
    private struct CurrentValues: Decodable {
        let values: [String: Double]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var values: [String: Double] = [:]
            for key in container.allKeys {
                if let value = try? container.decode(Double.self, forKey: key), value.isFinite {
                    values[key.stringValue] = value
                }
            }
            self.values = values
        }

        func number(_ name: String) -> Double? { values[name] }
    }

    /// Column-oriented series that keeps missing observations as nil rather than zero.
    struct Series: Decodable {
        let time: [Double]
        let columns: [String: [Double?]]

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: DynamicKey.self)
            time = try values.decode([Double].self, forKey: DynamicKey(stringValue: "time"))
            var columns: [String: [Double?]] = [:]
            for key in values.allKeys where key.stringValue != "time" {
                columns[key.stringValue] = try values.decodeIfPresent([Double?].self, forKey: key)
            }
            self.columns = columns
        }

        func validate() throws {
            guard time.allSatisfy({ $0.isFinite && $0 > 0 }),
                  zip(time, time.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
                  columns.values.allSatisfy({ $0.count == time.count }) else {
                throw DreadcastError.invalidResponse("Open-Meteo")
            }
        }

        func number(_ name: String, _ index: Int) -> Double? {
            guard let value = columns[name]?[index], value.isFinite else { return nil }
            return value
        }

        func nonnegative(_ name: String, _ index: Int) -> Double? {
            number(name, index).flatMap { $0 >= 0 ? $0 : nil }
        }

        func probability(_ name: String, _ index: Int) -> Double? {
            number(name, index).flatMap { (0...100).contains($0) ? $0 : nil }
        }

        func code(_ index: Int) -> Int? {
            number("weather_code", index).flatMap { (0...99).contains($0) ? Int($0) : nil }
        }
    }

    struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// Current US AQI at one point, from Open-Meteo's CAMS-based air-quality API.
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

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public func reading(at coordinate: GeoCoordinate, now: Date = Date()) async throws -> AirQualityReading {
        var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        let c = coordinate.coarsened
        components.queryItems = [
            .init(name: "latitude", value: String(c.latitude)),
            .init(name: "longitude", value: String(c.longitude)),
            .init(name: "current", value: "us_aqi,pm2_5,pm10,ozone,dust"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "GMT")
        ]
        struct Response: Decodable {
            struct Current: Decodable {
                let time: Double
                let us_aqi: Double?
                let pm2_5: Double?
                let pm10: Double?
                let ozone: Double?
                let dust: Double?
            }
            let current: Current?
        }
        let response = try await http.json(Response.self, from: components.url!, source: "Open-Meteo air quality")
        guard let current = response.current, let aqi = current.us_aqi, aqi.isFinite, aqi >= 0 else {
            throw DreadcastError.unavailable("Air quality is unavailable for this location.")
        }
        return AirQualityReading(fetchedAt: now, time: Date(timeIntervalSince1970: current.time),
                                 usAQI: Int(aqi.rounded()), pm2_5: current.pm2_5, pm10: current.pm10,
                                 ozone: current.ozone, dust: current.dust)
    }
}
