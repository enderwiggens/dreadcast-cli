import Foundation

/// Requests to the Dreadcast API for weather, air quality and place search
/// (dreadcast-server `docs/API.md`). The API keeps one reading per place for every
/// client, so the CLI never calls the providers behind it itself.
enum DreadcastAPI {
    static let source = "The Dreadcast API"

    /// `path` under the API's base URL, with `items` as its query.
    static func url(_ api: URL, _ path: String, _ items: [URLQueryItem]) -> URL? {
        var components = URLComponents(url: api.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = items
        return components?.url
    }

    /// The rounded coordinate as `lat` and `lon`.
    static func coordinate(_ coordinate: GeoCoordinate) -> [URLQueryItem] {
        let c = coordinate.coarsened
        return [URLQueryItem(name: "lat", value: String(c.latitude)), URLQueryItem(name: "lon", value: String(c.longitude))]
    }

    /// One answer, with the API's outages and limits said plainly. `what` names the data,
    /// as in "Weather".
    static func data(_ http: HTTPClient, _ url: URL?, what: String, maximumBytes: Int) async throws -> Data {
        guard let url else { throw DreadcastError.invalidResponse(source) }
        do {
            return try await http.data(url, accept: "application/json", timeout: 20, maximumBytes: maximumBytes, source: source)
        } catch DreadcastError.httpStatus(let status, _) where status == 502 || status == 503 || status == 504 {
            throw DreadcastError.unavailable("\(what) is unavailable right now")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(T.self, from: data) }
        catch { throw DreadcastError.invalidResponse(source) }
    }

    /// `location` in every answer: the rounded coordinate and the place's time zone.
    struct Location: Decodable {
        let latitude: Double
        let longitude: Double
        let timezone: String?
        let utcOffsetSeconds: Int?

        /// The IANA name when it looks like one; anything else is left out.
        var timeZoneIdentifier: String? {
            guard let timezone, timezone.count <= 64,
                  timezone.range(of: #"^[A-Za-z][A-Za-z0-9_+\-]*(/[A-Za-z0-9_+\-]+)*$"#, options: .regularExpression) != nil else { return nil }
            return timezone
        }

        /// UTC offsets run from −12 to +14 hours.
        var offset: Int? { utcOffsetSeconds.flatMap { (-12 * 3600...14 * 3600).contains($0) ? $0 : nil } }
    }

    /// `source` in every answer: whom to credit, and how old the reading is.
    struct Source: Decodable {
        let fetchedAt: String?
        let stale: Bool?
    }
}
