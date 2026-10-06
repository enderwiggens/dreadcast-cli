import Foundation

// MARK: - Solar activity

public struct SolarSample: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable { case observed, estimated, predicted }
    public var id: Date { time }
    public let time: Date
    public let kp: Double
    public let kind: Kind
    public let stormScale: String?
}

public struct SolarOutlook: Codable, Sendable {
    public let fetchedAt: Date
    public let samples: [SolarSample]

    public func latestObserved(at now: Date) -> SolarSample? {
        samples.last { $0.kind == .observed && $0.time <= now }
    }

    /// The highest forecast block that has not yet ended.
    public func peak(after now: Date, within hours: Double = 72) -> SolarSample? {
        samples.filter { $0.time.addingTimeInterval(3 * 3600) > now && $0.time <= now.addingTimeInterval(hours * 3600) && $0.kind != .observed }
            .max { $0.kp < $1.kp }
    }

    /// NOAA G-scale for a Kp value: Kp 5 is G1 through Kp 9 as G5.
    public static func geomagneticScale(kp: Double) -> String? {
        switch kp {
        case 9...: "G5"
        case 8..<9: "G4"
        case 7..<8: "G3"
        case 6..<7: "G2"
        case 5..<6: "G1"
        default: nil
        }
    }
}

// MARK: - Earthquakes

public struct Earthquake: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let magnitude: Double
    public let place: String
    public let time: Date
    public let coordinate: GeoCoordinate
    public let depthKM: Double

    public var sourceURL: URL {
        URL(string: "https://earthquake.usgs.gov/earthquakes/eventpage/")!.appendingPathComponent(id)
    }
}

public struct EarthquakeSnapshot: Equatable, Sendable, Codable {
    public let generatedAt: Date
    public let events: [Earthquake]
    public var discardedEvents: Int = 0
}

// MARK: - Aurora

/// The OVATION aurora probability near one location.
public struct AuroraReading: Codable, Sendable {
    public let observedAt: Date
    public let forecastAt: Date
    /// Probability of visible aurora overhead, 0–100, at the nearest grid cell.
    public let probability: Double
    /// The highest probability within about 10° of latitude toward the pole.
    public let poleward: Double
}

public struct AuroraSnapshot: Equatable, Sendable {
    public struct Cell: Equatable, Sendable {
        public let longitude: Double
        public let latitude: Double
        public let intensity: Double
    }
    public let observedAt: Date
    public let forecastAt: Date
    public let cells: [Cell]

    public func reading(at coordinate: GeoCoordinate) -> AuroraReading {
        let lon = coordinate.longitude.rounded()
        let lat = coordinate.latitude.rounded()
        var here = 0.0
        var poleward = 0.0
        let towardPole: (Double) -> Bool = coordinate.latitude >= 0
            ? { $0 >= lat && $0 <= lat + 10 }
            : { $0 <= lat && $0 >= lat - 10 }
        for cell in cells where abs(cell.longitude - lon) <= 1 || abs(abs(cell.longitude - lon) - 360) <= 1 {
            if cell.latitude == lat && cell.longitude == lon { here = cell.intensity }
            if towardPole(cell.latitude) { poleward = max(poleward, cell.intensity) }
        }
        return AuroraReading(observedAt: observedAt, forecastAt: forecastAt, probability: here, poleward: poleward)
    }
}

// MARK: - Decoders and service

public enum OutlookDecoder {
    public static func solar(_ data: Data) throws -> [SolarSample] {
        struct Row: Decodable {
            let time_tag: String
            let kp: Double?
            let observed: String
            let noaa_scale: String?
        }
        let rows: [Row]
        do { rows = try JSONDecoder().decode([Row].self, from: data) }
        catch { throw DreadcastError.invalidResponse("NOAA SWPC") }
        guard rows.count <= 1000 else { throw DreadcastError.invalidResponse("NOAA SWPC") }
        var seen = Set<Date>()
        let result = rows.compactMap { row -> SolarSample? in
            guard let time = date(row.time_tag), let kp = row.kp, kp.isFinite, (0...9).contains(kp),
                  let kind = SolarSample.Kind(rawValue: row.observed), seen.insert(time).inserted else { return nil }
            let scale = row.noaa_scale.flatMap { ["G1", "G2", "G3", "G4", "G5"].contains($0) ? $0 : nil }
            return SolarSample(time: time, kp: kp, kind: kind, stormScale: scale)
        }.sorted { $0.time < $1.time }
        guard !result.isEmpty else { throw DreadcastError.invalidResponse("NOAA SWPC") }
        return result
    }

    public static func earthquakes(_ data: Data, now: Date) throws -> EarthquakeSnapshot {
        struct Payload: Decodable {
            struct Metadata: Decodable { let generated: Double }
            struct Feature: Decodable {
                struct Geometry: Decodable { let type: String; let coordinates: [Double] }
                struct Properties: Decodable {
                    let mag: Double?; let place: String?; let time: Double?; let type: String?
                }
                let id: String; let geometry: Geometry?; let properties: Properties
            }
            let type: String; let metadata: Metadata; let features: [Feature]
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw DreadcastError.invalidResponse("USGS") }
        guard payload.type == "FeatureCollection", payload.metadata.generated.isFinite,
              payload.metadata.generated > 0, payload.features.count <= 10000 else { throw DreadcastError.invalidResponse("USGS") }
        var seen = Set<String>()
        var discarded = 0
        let events = payload.features.compactMap { feature -> Earthquake? in
            if let type = feature.properties.type, type != "earthquake" { return nil }
            if let magnitude = feature.properties.mag, magnitude.isFinite, magnitude < 2.5 { return nil }
            guard let geometry = feature.geometry, geometry.type == "Point", geometry.coordinates.count >= 3,
                  let magnitude = feature.properties.mag, magnitude.isFinite, (2.5...10).contains(magnitude),
                  let timestamp = feature.properties.time, timestamp.isFinite,
                  !feature.id.isEmpty, feature.id.count < 100,
                  feature.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  seen.insert(feature.id).inserted else { discarded += 1; return nil }
            let lon = geometry.coordinates[0], lat = geometry.coordinates[1], depth = geometry.coordinates[2]
            let time = Date(timeIntervalSince1970: timestamp / 1000)
            guard [lon, lat, depth].allSatisfy(\.isFinite), (-180...180).contains(lon), (-90...90).contains(lat),
                  (-10...1000).contains(depth), now.timeIntervalSince(time) >= -300 else { discarded += 1; return nil }
            if now.timeIntervalSince(time) > 86400 { return nil }
            return Earthquake(id: feature.id, magnitude: magnitude,
                              place: String((feature.properties.place ?? "Location not reported").prefix(200)),
                              time: time, coordinate: GeoCoordinate(latitude: lat, longitude: lon), depthKM: depth)
        }.sorted { $0.time > $1.time }
        return EarthquakeSnapshot(generatedAt: Date(timeIntervalSince1970: payload.metadata.generated / 1000),
                                  events: events, discardedEvents: discarded)
    }

    public static func aurora(_ data: Data) throws -> AuroraSnapshot {
        struct Payload: Decodable {
            let observation: String; let forecast: String; let coordinates: [[Double]]
            enum CodingKeys: String, CodingKey {
                case observation = "Observation Time", forecast = "Forecast Time", coordinates
            }
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw DreadcastError.invalidResponse("NOAA SWPC") }
        guard let observed = date(payload.observation), let forecast = date(payload.forecast),
              forecast >= observed, forecast.timeIntervalSince(observed) <= 10800,
              payload.coordinates.count <= 70000 else { throw DreadcastError.invalidResponse("NOAA SWPC") }
        let cells = payload.coordinates.compactMap { row -> AuroraSnapshot.Cell? in
            guard row.count == 3, row.allSatisfy(\.isFinite), (0...360).contains(row[0]),
                  (-90...90).contains(row[1]), (0...100).contains(row[2]) else { return nil }
            return .init(longitude: row[0] >= 180 ? row[0] - 360 : row[0], latitude: row[1], intensity: row[2])
        }
        guard !cells.isEmpty else { throw DreadcastError.invalidResponse("NOAA SWPC") }
        return AuroraSnapshot(observedAt: observed, forecastAt: forecast, cells: cells)
    }

    static func date(_ string: String) -> Date? {
        ISODate.parse(string.hasSuffix("Z") ? string : string + "Z")
    }
}

public struct OutlookService: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public func solar(now: Date = Date()) async throws -> SolarOutlook {
        let url = URL(string: "https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json")!
        let data = try await http.data(url, timeout: 15, maximumBytes: 1024 * 1024, source: "NOAA SWPC")
        return SolarOutlook(fetchedAt: now, samples: try OutlookDecoder.solar(data))
    }

    public func earthquakes(now: Date = Date()) async throws -> EarthquakeSnapshot {
        let url = URL(string: "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson")!
        let data = try await http.data(url, timeout: 15, maximumBytes: 8 * 1024 * 1024, source: "USGS")
        return try OutlookDecoder.earthquakes(data, now: now)
    }

    public func aurora(at coordinate: GeoCoordinate) async throws -> AuroraReading {
        let url = URL(string: "https://services.swpc.noaa.gov/json/ovation_aurora_latest.json")!
        let data = try await http.data(url, timeout: 20, maximumBytes: 8 * 1024 * 1024, source: "NOAA SWPC")
        return try OutlookDecoder.aurora(data).reading(at: coordinate)
    }
}

// MARK: - Meteor showers

/// Dated peak nights from the American Meteor Society calendar, checked 2026-10-03.
/// Deliberately not a recurring calendar: once this edition no longer covers the
/// current date, dreadcast says the calendar needs an update.
public enum MeteorCalendar {
    public static let sourceURL = URL(string: "https://www.amsmeteors.org/calendar/")!

    public struct Shower: Identifiable, Sendable {
        public var id: String { "\(name)-\(year)" }
        public let name: String
        public let year: Int
        public let month: Int
        public let day: Int
        public let endDay: Int
        /// Typical zenithal hourly rate under dark skies.
        public let rate: Int

        public var peakLabel: String {
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            return "\(months[month - 1]) \(day)–\(endDay)"
        }

        /// 11 PM local on the first peak night.
        public func peakDate(in timeZone: TimeZone) -> Date {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 23))!
        }
    }

    public static let showers: [Shower] = [
        .init(name: "Orionids", year: 2026, month: 10, day: 21, endDay: 22, rate: 20),
        .init(name: "Southern Taurids", year: 2026, month: 11, day: 4, endDay: 5, rate: 5),
        .init(name: "Northern Taurids", year: 2026, month: 11, day: 11, endDay: 12, rate: 5),
        .init(name: "Leonids", year: 2026, month: 11, day: 16, endDay: 17, rate: 15),
        .init(name: "Geminids", year: 2026, month: 12, day: 13, endDay: 14, rate: 120),
        .init(name: "Ursids", year: 2026, month: 12, day: 21, endDay: 22, rate: 10),
        .init(name: "Quadrantids", year: 2027, month: 1, day: 3, endDay: 4, rate: 120),
        .init(name: "Lyrids", year: 2027, month: 4, day: 21, endDay: 22, rate: 18),
        .init(name: "Eta Aquariids", year: 2027, month: 5, day: 5, endDay: 6, rate: 50),
        .init(name: "Southern Delta Aquariids", year: 2027, month: 7, day: 30, endDay: 31, rate: 25),
        .init(name: "Alpha Capricornids", year: 2027, month: 7, day: 30, endDay: 31, rate: 5),
        .init(name: "Perseids", year: 2027, month: 8, day: 12, endDay: 13, rate: 100)
    ]

    public static func upcoming(at now: Date, timeZone: TimeZone) -> [Shower] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return showers.filter {
            let lastMorning = calendar.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.endDay, hour: 12))!
            return lastMorning >= now
        }
    }
}

// MARK: - Moon

public enum LunarPhaseName: Int, CaseIterable, Sendable {
    case newMoon, waxingCrescent, firstQuarter, waxingGibbous
    case fullMoon, waningGibbous, lastQuarter, waningCrescent

    public var displayName: String {
        switch self {
        case .newMoon: "New moon"
        case .waxingCrescent: "Waxing crescent"
        case .firstQuarter: "First quarter"
        case .waxingGibbous: "Waxing gibbous"
        case .fullMoon: "Full moon"
        case .waningGibbous: "Waning gibbous"
        case .lastQuarter: "Last quarter"
        case .waningCrescent: "Waning crescent"
        }
    }
}

/// Approximate geocentric phase and illumination.
/// Adapted from SunCalc 1.9.0 (BSD-2-Clause), Copyright (c) 2014, Vladimir Agafonkin.
/// https://github.com/mourner/suncalc/blob/v1.9.0/suncalc.js — see THIRD_PARTY_NOTICES.md.
public struct LunarPhase: Sendable {
    /// Progress around the cycle: 0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter.
    public let phase: Double
    public let illumination: Double
    public var isWaxing: Bool { phase < 0.5 }
    public var name: LunarPhaseName { LunarPhaseName.allCases[Int((phase * 8).rounded()) % 8] }

    public init(at date: Date) {
        let radians = Double.pi / 180
        let days = date.timeIntervalSince1970 / 86400 - 10957.5
        let obliquity = 23.4397 * radians
        func coordinates(longitude: Double, latitude: Double) -> (ra: Double, dec: Double) {
            (atan2(sin(longitude) * cos(obliquity) - tan(latitude) * sin(obliquity), cos(longitude)),
             asin(sin(latitude) * cos(obliquity) + cos(latitude) * sin(obliquity) * sin(longitude)))
        }
        let solarAnomaly = radians * (357.5291 + 0.98560028 * days)
        let solarCenter = radians * (1.9148 * sin(solarAnomaly) + 0.02 * sin(2 * solarAnomaly) + 0.0003 * sin(3 * solarAnomaly))
        let sun = coordinates(longitude: solarAnomaly + solarCenter + 102.9372 * radians + .pi, latitude: 0)
        let lunarAnomaly = radians * (134.963 + 13.064993 * days)
        let lunarLongitude = radians * (218.316 + 13.176396 * days) + radians * 6.289 * sin(lunarAnomaly)
        let lunarLatitude = radians * 5.128 * sin(radians * (93.272 + 13.229350 * days))
        let lunarDistance = 385001 - 20905 * cos(lunarAnomaly)
        let moon = coordinates(longitude: lunarLongitude, latitude: lunarLatitude)
        let sunDistance = 149_598_000.0
        let separationCosine = sin(sun.dec) * sin(moon.dec) + cos(sun.dec) * cos(moon.dec) * cos(sun.ra - moon.ra)
        let separation = acos(min(1, max(-1, separationCosine)))
        let incidence = atan2(sunDistance * sin(separation), lunarDistance - sunDistance * cos(separation))
        let angle = atan2(cos(sun.dec) * sin(sun.ra - moon.ra),
                          sin(sun.dec) * cos(moon.dec) - cos(sun.dec) * sin(moon.dec) * cos(sun.ra - moon.ra))
        illumination = min(1, max(0, (1 + cos(incidence)) / 2))
        phase = min(1, max(0, 0.5 + 0.5 * incidence * (angle < 0 ? -1 : 1) / .pi))
    }
}
