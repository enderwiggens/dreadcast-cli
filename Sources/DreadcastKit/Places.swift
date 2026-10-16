import Foundation

/// A saved or searched location. Coordinates are always coarsened to two decimals.
public struct Place: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case zip, search, coordinates }

    public var name: String
    public var coordinate: GeoCoordinate
    public var countryCode: String?
    public var region: String?
    public var timeZone: String?
    public var source: Source

    public init(name: String, coordinate: GeoCoordinate, countryCode: String? = nil,
                region: String? = nil, timeZone: String? = nil, source: Source) {
        self.name = name
        self.coordinate = coordinate.coarsened
        self.countryCode = countryCode
        self.region = region
        self.timeZone = timeZone
        self.source = source
    }

    /// NWS alerts, SPC outlooks and NIFC fires cover the United States and its territories.
    public var isUnitedStates: Bool {
        guard let code = countryCode?.uppercased() else {
            // Coordinate-only places: approximate US coverage by bounding boxes.
            return USCoverage.contains(coordinate)
        }
        return ["US", "PR", "GU", "VI", "AS", "MP"].contains(code)
    }
}

enum USCoverage {
    /// Coarse boxes for CONUS, Alaska, Hawaii, Puerto Rico and Guam.
    static func contains(_ c: GeoCoordinate) -> Bool {
        let boxes: [(Double, Double, Double, Double)] = [
            (24.0, 49.6, -125.0, -66.5),   // CONUS
            (51.0, 71.6, -179.9, -129.9),  // Alaska
            (18.8, 22.4, -160.6, -154.6),  // Hawaii
            (17.8, 18.6, -67.4, -65.1),    // Puerto Rico
            (13.2, 13.8, 144.5, 145.1)     // Guam
        ]
        return boxes.contains { c.latitude >= $0.0 && c.latitude <= $0.1 && c.longitude >= $0.2 && c.longitude <= $0.3 }
    }
}

public struct PlaceService: Sendable {
    private let http: HTTPClient
    private let api: URL?

    /// Place names are searched through the Dreadcast API at `api`; without it, only ZIP
    /// codes and coordinates resolve.
    public init(http: HTTPClient = HTTPClient(), api: URL?) {
        self.http = http
        self.api = api
    }

    /// Interprets a query as a five-digit US ZIP code, a "lat,lon" pair, or a place name.
    public func resolve(_ query: String) async throws -> [Place] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DreadcastError.notFound("Enter a ZIP code, a place name, or latitude,longitude.") }
        if let coordinate = Self.parseCoordinates(trimmed) {
            return [Place(name: coordinate.coarsened.formatted, coordinate: coordinate,
                          countryCode: USCoverage.contains(coordinate) ? "US" : nil, source: .coordinates)]
        }
        if trimmed.count == 5, trimmed.allSatisfy(\.isNumber) {
            return [try await lookupZIP(trimmed)]
        }
        return try await search(trimmed)
    }

    public func lookupZIP(_ zip: String) async throws -> Place {
        guard zip.count == 5, zip.allSatisfy(\.isNumber),
              let url = URL(string: "https://api.zippopotam.us/us/\(zip)") else {
            throw DreadcastError.notFound("Enter a five-digit US ZIP code.")
        }
        struct Response: Decodable {
            struct Entry: Decodable {
                let latitude: String
                let longitude: String
                let name: String
                let state: String
                enum CodingKeys: String, CodingKey {
                    case latitude, longitude
                    case name = "place name"
                    case state = "state abbreviation"
                }
            }
            let places: [Entry]
        }
        let response: Response
        do {
            response = try await http.json(Response.self, from: url, source: "Zippopotam.us")
        } catch DreadcastError.httpStatus(404, _) {
            throw DreadcastError.notFound("ZIP code \(zip) wasn’t found.")
        }
        guard let entry = response.places.first,
              let latitude = Double(entry.latitude), let longitude = Double(entry.longitude) else {
            throw DreadcastError.notFound("ZIP code \(zip) wasn’t found.")
        }
        return Place(name: "\(entry.name), \(entry.state)",
                     coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
                     countryCode: "US", region: entry.state, source: .zip)
    }

    /// Worldwide place search through the Dreadcast API's `/v1/places/search`, which
    /// gets GeoNames' places from Open-Meteo.
    public func search(_ name: String, count: Int = 6) async throws -> [Place] {
        guard let api else {
            throw DreadcastError.unavailable("Place search comes from the Dreadcast API, which `api-url off` turns off. Use a ZIP code or latitude,longitude.")
        }
        let query = String(name.prefix(100))
        guard query.count >= 2 else { throw DreadcastError.notFound("Enter at least two letters of a place name.") }
        let url = DreadcastAPI.url(api, "v1/places/search", [URLQueryItem(name: "q", value: query),
                                                             URLQueryItem(name: "count", value: String(max(1, min(count, 10))))])
        let data = try await DreadcastAPI.data(http, url, what: "Place search", maximumBytes: 256 * 1024)
        let places = try Self.places(data)
        guard !places.isEmpty else { throw DreadcastError.notFound("No places matched “\(name)”.") }
        return places
    }

    /// The API's results as places, labeled as people write them. Text the terminal
    /// prints loses control characters.
    static func places(_ data: Data) throws -> [Place] {
        struct Answer: Decodable {
            struct Result: Decodable {
                let name: String
                let latitude: Double
                let longitude: Double
                let countryCode: String?
                let country: String?
                let admin1: String?
                let timezone: String?
            }
            let results: [Result]
        }
        func clean(_ text: String?) -> String? {
            let kept = String(String.UnicodeScalarView((text ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
                .trimmingCharacters(in: .whitespaces)
            return kept.isEmpty ? nil : String(kept.prefix(200))
        }
        return try DreadcastAPI.decode(Answer.self, from: data).results.compactMap { result -> Place? in
            let coordinate = GeoCoordinate(latitude: result.latitude, longitude: result.longitude)
            guard coordinate.isValid, let name = clean(result.name) else { return nil }
            let code = clean(result.countryCode)?.uppercased()
            let admin = clean(result.admin1), country = clean(result.country)
            var label = name
            if code == "US", let admin {
                label += ", " + (USStates.abbreviation(for: admin) ?? admin)
            } else if let admin, admin != name {
                label += ", " + admin + (country.map { ", " + $0 } ?? "")
            } else if let country {
                label += ", " + country
            }
            return Place(name: label, coordinate: coordinate, countryCode: code,
                         region: admin, timeZone: clean(result.timezone), source: .search)
        }
    }

    /// Accepts "27.95,-82.46", "27.95 -82.46" or "27.95, -82.46".
    public static func parseCoordinates(_ text: String) -> GeoCoordinate? {
        let separators = CharacterSet(charactersIn: ", ").union(.whitespaces)
        let parts = text.components(separatedBy: separators).filter { !$0.isEmpty }
        guard parts.count == 2,
              let latitude = Double(parts[0].replacingOccurrences(of: "−", with: "-")),
              let longitude = Double(parts[1].replacingOccurrences(of: "−", with: "-")) else { return nil }
        let coordinate = GeoCoordinate(latitude: latitude, longitude: longitude)
        return coordinate.isValid ? coordinate : nil
    }
}

enum USStates {
    static let byName: [String: String] = [
        "Alabama": "AL", "Alaska": "AK", "Arizona": "AZ", "Arkansas": "AR", "California": "CA",
        "Colorado": "CO", "Connecticut": "CT", "Delaware": "DE", "District of Columbia": "DC",
        "Florida": "FL", "Georgia": "GA", "Hawaii": "HI", "Idaho": "ID", "Illinois": "IL",
        "Indiana": "IN", "Iowa": "IA", "Kansas": "KS", "Kentucky": "KY", "Louisiana": "LA",
        "Maine": "ME", "Maryland": "MD", "Massachusetts": "MA", "Michigan": "MI", "Minnesota": "MN",
        "Mississippi": "MS", "Missouri": "MO", "Montana": "MT", "Nebraska": "NE", "Nevada": "NV",
        "New Hampshire": "NH", "New Jersey": "NJ", "New Mexico": "NM", "New York": "NY",
        "North Carolina": "NC", "North Dakota": "ND", "Ohio": "OH", "Oklahoma": "OK", "Oregon": "OR",
        "Pennsylvania": "PA", "Rhode Island": "RI", "South Carolina": "SC", "South Dakota": "SD",
        "Tennessee": "TN", "Texas": "TX", "Utah": "UT", "Vermont": "VT", "Virginia": "VA",
        "Washington": "WA", "West Virginia": "WV", "Wisconsin": "WI", "Wyoming": "WY",
        "Puerto Rico": "PR", "Guam": "GU"
    ]

    static func abbreviation(for name: String) -> String? { byName[name] }
}
