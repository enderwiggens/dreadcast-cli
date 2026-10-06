import Foundation

/// An active NWS watch, warning, advisory or statement.
public struct WeatherAlert: Identifiable, Equatable, Sendable, Codable {
    public enum Category: String, Sendable, Codable {
        case flood, tornado, thunderstorm, hail, tropical, winter, heat, fire
        case airQuality, fog, wind, marine, rain, general
    }

    /// NWS CAP severity, ordered from least to most severe.
    public enum Severity: String, Sendable, Codable, Comparable, CaseIterable {
        case unknown, minor, moderate, severe, extreme

        public init(_ value: String?) {
            self = value.flatMap { Severity(rawValue: $0.lowercased()) } ?? .unknown
        }

        private var rank: Int {
            switch self {
            case .unknown: 0
            case .minor: 1
            case .moderate: 2
            case .severe: 3
            case .extreme: 4
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    /// The kind of product, derived from the event name.
    public enum Level: String, Sendable, Codable, Comparable {
        case statement, advisory, watch, warning

        private var rank: Int {
            switch self {
            case .statement: 0
            case .advisory: 1
            case .watch: 2
            case .warning: 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    public let id: String
    public let event: String
    public let headline: String
    public let areaDescription: String
    public let description: String
    public let instruction: String?
    public let severity: Severity
    public let urgency: String?
    public let certainty: String?
    public let sender: String?
    public let effective: Date?
    public let onset: Date?
    public let expires: Date?
    public let ends: Date?
    public let messageType: String?

    public init(id: String, event: String, headline: String, areaDescription: String, description: String,
                instruction: String?, severity: Severity, urgency: String? = nil, certainty: String? = nil,
                sender: String? = nil, effective: Date? = nil, onset: Date? = nil, expires: Date? = nil,
                ends: Date? = nil, messageType: String? = nil) {
        self.id = id; self.event = event; self.headline = headline; self.areaDescription = areaDescription
        self.description = description; self.instruction = instruction; self.severity = severity
        self.urgency = urgency; self.certainty = certainty; self.sender = sender; self.effective = effective
        self.onset = onset; self.expires = expires; self.ends = ends; self.messageType = messageType
    }

    /// The time the hazard ends, falling back to the product's expiration.
    public var endsOrExpires: Date? { ends ?? expires }

    public var level: Level {
        let event = event.lowercased()
        if event.contains("warning") { return .warning }
        if event.contains("watch") { return .watch }
        if event.contains("advisory") { return .advisory }
        return .statement
    }

    public var category: Category {
        // The event name is authoritative. Descriptions often mention secondary
        // hazards, so combining every field can assign the wrong primary hazard.
        for text in [event, headline, description] {
            if let category = Self.category(in: text.lowercased()) { return category }
        }
        return .general
    }

    static func category(in text: String) -> Category? {
        if text.contains("hurricane force wind") { return .wind }
        if text.contains("hurricane") || text.contains("tropical storm") ||
            text.contains("tropical cyclone") || text.contains("typhoon") {
            return .tropical
        }
        if text.contains("tornado") || text.contains("funnel cloud") { return .tornado }
        if text.contains("flash flood") || text.contains("flood") ||
            text.contains("storm surge") || text.contains("tsunami") ||
            text.contains("hydrologic") {
            return .flood
        }
        if text.contains("thunderstorm") || text.contains("lightning") { return .thunderstorm }
        if text.contains("hail") { return .hail }
        if text.contains("blizzard") || text.contains("snow") || text.contains("winter") ||
            text.contains("ice storm") || text.contains("freez") ||
            text.contains("extreme cold") || text.contains("wind chill") ||
            text.contains("frost") {
            return .winter
        }
        if text.contains("excessive heat") || text.contains("heat advisory") ||
            text.contains("extreme heat") || text.contains("heat warning") {
            return .heat
        }
        if text.contains("red flag") || text.contains("fire weather") ||
            text.contains("wildfire") || text.contains("fire warning") {
            return .fire
        }
        if text.contains("air quality") || text.contains("smoke") ||
            text.contains("dust storm") || text.contains("blowing dust") ||
            text.contains("dust advisory") || text.contains("ashfall") {
            return .airQuality
        }
        if text.contains("dense fog") || text.contains("fog advisory") { return .fog }
        if text.contains("high wind") || text.contains("wind advisory") ||
            text.contains("extreme wind") || text.contains("gale warning") {
            return .wind
        }
        if text.contains("small craft") || text.contains("marine warning") ||
            text.contains("special marine") || text.contains("storm warning") ||
            text.contains("rip current") || text.contains("high surf") ||
            text.contains("beach hazard") {
            return .marine
        }
        if text.contains("heavy rain") || text.contains("excessive rainfall") ||
            text.contains("rainfall") {
            return .rain
        }
        return nil
    }

    /// Alerts sort by product level, then severity, then soonest expiry.
    public static func threatOrder(_ lhs: WeatherAlert, _ rhs: WeatherAlert) -> Bool {
        if lhs.level != rhs.level { return lhs.level > rhs.level }
        if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
        return (lhs.endsOrExpires ?? .distantFuture) < (rhs.endsOrExpires ?? .distantFuture)
    }
}

public struct AlertService: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    /// Active alerts for the forecast zone and county containing `point`.
    public func activeAlerts(at point: GeoCoordinate) async throws -> [WeatherAlert] {
        var components = URLComponents(string: "https://api.weather.gov/alerts/active")!
        let c = point.coarsened
        components.queryItems = [.init(name: "point", value: "\(c.latitude),\(c.longitude)")]
        let data: Data
        do {
            data = try await http.data(components.url!, accept: "application/geo+json", timeout: 15,
                                       maximumBytes: 12 * 1024 * 1024, source: "NWS")
        } catch DreadcastError.httpStatus(let status, _) where status == 400 || status == 404 {
            throw DreadcastError.unsupportedRegion("NWS alerts cover the United States and its territories.")
        }
        return try Self.decode(data)
    }

    public static func decode(_ data: Data) throws -> [WeatherAlert] {
        let payload: FeatureCollection<NWSAlertProperties>
        do {
            payload = try JSONDecoder().decode(FeatureCollection<NWSAlertProperties>.self, from: data)
        } catch {
            throw DreadcastError.invalidResponse("NWS")
        }
        var seen = Set<String>()
        return payload.features.compactMap { feature -> WeatherAlert? in
            guard let p = feature.properties else { return nil }
            if let status = p.status, status.lowercased() != "actual" { return nil }
            let headline = p.headline ?? p.event
            let id = p.id ?? feature.id?.value ?? headline
            guard seen.insert(id).inserted else { return nil }
            return WeatherAlert(
                id: id, event: p.event, headline: headline, areaDescription: p.areaDescription,
                description: p.description ?? "", instruction: p.instruction, severity: .init(p.severity),
                urgency: p.urgency, certainty: p.certainty, sender: p.senderName,
                effective: ISODate.parse(p.effective), onset: ISODate.parse(p.onset),
                expires: ISODate.parse(p.expires), ends: ISODate.parse(p.ends), messageType: p.messageType
            )
        }
        .sorted(by: WeatherAlert.threatOrder)
    }

    private struct NWSAlertProperties: Decodable, Sendable {
        let id: String?
        let areaDescription: String
        let effective: String?
        let onset: String?
        let expires: String?
        let ends: String?
        let status: String?
        let messageType: String?
        let severity: String?
        let certainty: String?
        let urgency: String?
        let event: String
        let senderName: String?
        let headline: String?
        let description: String?
        let instruction: String?

        enum CodingKeys: String, CodingKey {
            case id, effective, onset, expires, ends, status, messageType, severity, certainty, urgency
            case event, senderName, headline, description, instruction
            case areaDescription = "areaDesc"
        }
    }
}

// MARK: - SPC Day 1 convective outlook

public struct SevereOutlook: Sendable {
    public enum Risk: Int, Comparable, Sendable, Codable {
        case none = 0, thunder, marginal, slight, enhanced, moderate, high

        init(label: String) {
            switch label.uppercased() {
            case "TSTM": self = .thunder
            case "MRGL": self = .marginal
            case "SLGT": self = .slight
            case "ENH": self = .enhanced
            case "MDT": self = .moderate
            case "HIGH": self = .high
            default: self = .none
            }
        }

        public var label: String {
            switch self {
            case .none: "None"
            case .thunder: "General thunder"
            case .marginal: "Marginal"
            case .slight: "Slight"
            case .enhanced: "Enhanced"
            case .moderate: "Moderate"
            case .high: "High"
            }
        }

        /// SPC's 1–5 categorical scale; general thunder is outside it.
        public var level: Int? { rawValue >= 2 ? rawValue - 1 : nil }

        public static func < (lhs: Risk, rhs: Risk) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Area: Sendable {
        public let risk: Risk
        public let polygons: [GeoPolygon]
        public let expires: Date?
    }

    public let areas: [Area]
    public let fetchedAt: Date

    /// The highest categorical risk whose polygons contain `point`.
    public func risk(at point: GeoCoordinate) -> (risk: Risk, expires: Date?) {
        var best: (Risk, Date?) = (.none, nil)
        for area in areas where area.risk > best.0 && area.polygons.contains(where: { $0.contains(point) }) {
            best = (area.risk, area.expires)
        }
        return best
    }
}

public struct SevereOutlookService: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public func day1(now: Date = Date()) async throws -> SevereOutlook {
        let url = URL(string: "https://www.spc.noaa.gov/products/outlook/day1otlk_cat.nolyr.geojson")!
        let data = try await http.data(url, accept: "application/geo+json", timeout: 20, maximumBytes: 12 * 1024 * 1024, source: "NOAA SPC")
        return try Self.decode(data, now: now)
    }

    public static func decode(_ data: Data, now: Date) throws -> SevereOutlook {
        struct Properties: Decodable, Sendable {
            let label: String
            let expireISO: String?
            enum CodingKeys: String, CodingKey { case label = "LABEL", expireISO = "EXPIRE_ISO" }
        }
        let payload: FeatureCollection<Properties>
        do { payload = try JSONDecoder().decode(FeatureCollection<Properties>.self, from: data) }
        catch { throw DreadcastError.invalidResponse("NOAA SPC") }
        let areas = payload.features.compactMap { feature -> SevereOutlook.Area? in
            guard let properties = feature.properties else { return nil }
            let polygons = feature.geometry?.polygons ?? []
            guard !polygons.isEmpty else { return nil }
            return .init(risk: .init(label: properties.label), polygons: polygons, expires: ISODate.parse(properties.expireISO))
        }
        return SevereOutlook(areas: areas, fetchedAt: now)
    }
}

// MARK: - NHC tropical cyclones

public struct TropicalStorm: Identifiable, Sendable, Codable {
    public let id: String
    public let name: String
    public let classification: String
    public let advisory: String?
    public let latitude: Double
    public let longitude: Double
    public let maximumWindKnots: Int?

    public var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }
}

public struct TropicalService: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    /// Active storms' current positions from the NHC tropical weather summary.
    public func activeStorms() async throws -> [TropicalStorm] {
        var components = URLComponents(string: "https://mapservices.weather.noaa.gov/tropical/rest/services/tropical/NHC_tropical_weather_summary/MapServer/5/query")!
        components.queryItems = [
            .init(name: "where", value: "1=1"),
            .init(name: "outFields", value: "*"),
            .init(name: "returnGeometry", value: "true"),
            .init(name: "f", value: "geojson")
        ]
        let data = try await http.data(components.url!, accept: "application/geo+json", timeout: 20, maximumBytes: 12 * 1024 * 1024, source: "NOAA NHC")
        return try Self.decode(data)
    }

    public static func decode(_ data: Data) throws -> [TropicalStorm] {
        struct Properties: Decodable, Sendable {
            let stormName: String
            let stormType: String
            let advisoryDate: String?
            let forecastHour: Int
            let development: String?
            let maximumWind: Int?
            let binNumber: String
            enum CodingKeys: String, CodingKey {
                case stormName = "stormname", stormType = "stormtype", advisoryDate = "advdate"
                case forecastHour = "tau", development = "tcdvlp", maximumWind = "maxwind", binNumber = "binnumber"
            }
        }
        let payload: FeatureCollection<Properties>
        do { payload = try JSONDecoder().decode(FeatureCollection<Properties>.self, from: data) }
        catch { throw DreadcastError.invalidResponse("NOAA NHC") }
        var best: [String: (hour: Int, storm: TropicalStorm)] = [:]
        for feature in payload.features {
            guard let p = feature.properties, let point = feature.geometry?.point else { continue }
            let storm = TropicalStorm(id: p.binNumber, name: p.stormName,
                                      classification: p.development ?? p.stormType, advisory: p.advisoryDate,
                                      latitude: point.latitude, longitude: point.longitude,
                                      maximumWindKnots: p.maximumWind)
            if let existing = best[p.binNumber], existing.hour <= p.forecastHour { continue }
            best[p.binNumber] = (p.forecastHour, storm)
        }
        return best.values.map(\.storm).sorted { $0.name < $1.name }
    }
}

// MARK: - NIFC wildfires

public struct Wildfire: Identifiable, Sendable, Codable {
    public let id: String
    public let name: String
    public let latitude: Double
    public let longitude: Double
    public let acres: Double?
    public let percentContained: Int?
    public let discoveredAt: Date?
    public let state: String?

    public var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }
}

public struct WildfireService: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    /// Active wildfire incident locations in a box around `center`.
    public func activeFires(near center: GeoCoordinate, radiusMiles: Double) async throws -> [Wildfire] {
        var components = URLComponents(string: "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Incident_Locations_Current/FeatureServer/0/query")!
        let radius = max(25, min(radiusMiles, 600))
        let latitudeDelta = radius / 69
        let longitudeDelta = radius / (69 * max(cos(center.latitude * .pi / 180), 0.2))
        let bounds = [
            max(-180, center.longitude - longitudeDelta), max(-90, center.latitude - latitudeDelta),
            min(180, center.longitude + longitudeDelta), min(90, center.latitude + latitudeDelta)
        ].map { String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ",")
        components.queryItems = [
            .init(name: "where", value: "IncidentTypeCategory = 'WF' AND ActiveFireCandidate = 1 AND FireOutDateTime IS NULL"),
            .init(name: "outFields", value: "IncidentName,IrwinID,IncidentSize,PercentContained,FireDiscoveryDateTime,POOState"),
            .init(name: "geometry", value: bounds),
            .init(name: "geometryType", value: "esriGeometryEnvelope"),
            .init(name: "inSR", value: "4326"),
            .init(name: "spatialRel", value: "esriSpatialRelIntersects"),
            .init(name: "returnGeometry", value: "true"),
            .init(name: "outSR", value: "4326"),
            .init(name: "f", value: "geojson")
        ]
        let data = try await http.data(components.url!, accept: "application/geo+json", timeout: 20, maximumBytes: 12 * 1024 * 1024, source: "NIFC")
        return try Self.decode(data)
            .filter { $0.coordinate.distanceMiles(to: center) <= radius }
    }

    public static func decode(_ data: Data) throws -> [Wildfire] {
        struct Properties: Decodable, Sendable {
            let name: String?
            let irwinID: String?
            let acres: Double?
            let percentContained: Int?
            let discovered: Double?
            let state: String?
            enum CodingKeys: String, CodingKey {
                case name = "IncidentName", irwinID = "IrwinID", acres = "IncidentSize"
                case percentContained = "PercentContained", discovered = "FireDiscoveryDateTime", state = "POOState"
            }
        }
        let payload: FeatureCollection<Properties>
        do { payload = try JSONDecoder().decode(FeatureCollection<Properties>.self, from: data) }
        catch { throw DreadcastError.invalidResponse("NIFC") }
        var seen = Set<String>()
        return payload.features.compactMap { feature -> Wildfire? in
            guard let p = feature.properties, let point = feature.geometry?.point else { return nil }
            let id = (p.irwinID ?? feature.id?.value ?? "\(point.latitude),\(point.longitude)")
                .trimmingCharacters(in: CharacterSet(charactersIn: "{}")).uppercased()
            guard seen.insert(id).inserted else { return nil }
            let state = p.state.map { $0.hasPrefix("US-") ? String($0.dropFirst(3)) : $0 }
            return Wildfire(id: id, name: (p.name ?? "Wildfire").capitalized, latitude: point.latitude,
                            longitude: point.longitude, acres: p.acres, percentContained: p.percentContained,
                            discoveredAt: p.discovered.map { Date(timeIntervalSince1970: $0 / 1000) }, state: state)
        }
    }
}
