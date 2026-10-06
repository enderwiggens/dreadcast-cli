import Foundation

public struct LightningStrike: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Sendable, Codable { case cloudToGround, intracloud, unknown }

    public let id: String
    public let coordinate: GeoCoordinate
    public let timestamp: Date
    public let kind: Kind
    public let peakAmps: Double?

    public init(id: String, coordinate: GeoCoordinate, timestamp: Date, kind: Kind, peakAmps: Double?) {
        self.id = id
        self.coordinate = coordinate
        self.timestamp = timestamp
        self.kind = kind
        self.peakAmps = peakAmps
    }

    public func ageBand(at date: Date) -> LightningAgeBand {
        LightningAgeBand(age: max(0, date.timeIntervalSince(timestamp)))
    }
}

/// Five four-minute bands covering the last 20 minutes, matching the Dreadcast app.
public enum LightningAgeBand: Int, CaseIterable, Hashable, Sendable {
    case newest, recent, warm, aging, oldest

    public init(age: TimeInterval) {
        switch age {
        case ..<240: self = .newest
        case ..<480: self = .recent
        case ..<720: self = .warm
        case ..<960: self = .aging
        default: self = .oldest
        }
    }

    public var label: String {
        switch self {
        case .newest: "0–4 min"
        case .recent: "4–8 min"
        case .warm: "8–12 min"
        case .aging: "12–16 min"
        case .oldest: "16–20 min"
        }
    }
}

public struct LightningCredentials: Sendable, Equatable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public var isComplete: Bool { !clientID.isEmpty && !clientSecret.isEmpty }
}

public struct LightningSnapshot: Codable, Sendable {
    public let fetchedAt: Date
    public let center: GeoCoordinate
    public let radiusMiles: Double
    public let strikes: [LightningStrike]

    public init(fetchedAt: Date, center: GeoCoordinate, radiusMiles: Double, strikes: [LightningStrike]) {
        self.fetchedAt = fetchedAt
        self.center = center
        self.radiusMiles = radiusMiles
        self.strikes = strikes
    }

    /// Strikes younger than 20 minutes at `now`.
    public func current(at now: Date) -> [LightningStrike] {
        strikes.filter { now.timeIntervalSince($0.timestamp) < 1200 && now.timeIntervalSince($0.timestamp) > -120 }
    }

    public func nearest(at now: Date) -> (strike: LightningStrike, miles: Double)? {
        current(at: now)
            .map { ($0, $0.coordinate.distanceMiles(to: center)) }
            .min { $0.1 < $1.1 }
    }
}

/// Xweather lightning, using the user's own credentials.
public struct XweatherLightningService: Sendable {
    public static let maximumRadiusMiles = 62.0
    private let credentials: LightningCredentials
    private let http: HTTPClient

    public init(credentials: LightningCredentials, http: HTTPClient = HTTPClient()) {
        self.credentials = credentials
        self.http = http
    }

    public func snapshot(center: GeoCoordinate, radiusMiles: Double, now: Date = Date()) async throws -> LightningSnapshot {
        guard credentials.isComplete else {
            throw DreadcastError.missingCredentials("Lightning needs Xweather credentials. Run `dread auth xweather`.")
        }
        let radius = min(radiusMiles, Self.maximumRadiusMiles)
        let c = center.coarsened
        var components = URLComponents(string: "https://data.api.xweather.com/lightning/closest")!
        components.queryItems = [
            .init(name: "p", value: "\(c.latitude),\(c.longitude)"),
            .init(name: "radius", value: "\(Int(radius.rounded()))miles"),
            .init(name: "limit", value: "1000"),
            .init(name: "filter", value: "all"),
            .init(name: "from", value: "-20minutes"),
            .init(name: "format", value: "json"),
            .init(name: "client_id", value: credentials.clientID),
            .init(name: "client_secret", value: credentials.clientSecret)
        ]
        let data: Data
        do {
            data = try await http.data(components.url!, accept: "application/json", timeout: 15, maximumBytes: 5 * 1024 * 1024, source: "Xweather")
        } catch DreadcastError.httpStatus(let status, _) where status == 401 || status == 403 {
            throw DreadcastError.missingCredentials("Xweather rejected the saved credentials. Run `dread auth xweather` to update them.")
        }
        let strikes = try Self.decode(data, now: now)
        return LightningSnapshot(fetchedAt: now, center: c, radiusMiles: radius, strikes: strikes)
    }

    public static func decode(_ data: Data, now: Date) throws -> [LightningStrike] {
        struct Response: Decodable {
            struct ErrorBody: Decodable { let code: String?; let description: String? }
            let success: Bool
            let error: ErrorBody?
            let response: [Record]?
        }
        struct Record: Decodable {
            struct Location: Decodable { let long: Double; let lat: Double }
            struct Observation: Decodable {
                struct Pulse: Decodable { let type: String?; let peakamp: Double? }
                let timestampMS: Double?
                let timestamp: Double?
                let pulse: Pulse?
            }
            let id: String
            let loc: Location
            let ob: Observation
        }
        let payload: Response
        do { payload = try JSONDecoder().decode(Response.self, from: data) }
        catch { throw DreadcastError.invalidResponse("Xweather") }
        guard payload.success else {
            // "warn_no_data" means the area simply has no strikes.
            if payload.error?.code == "warn_no_data" { return [] }
            if let code = payload.error?.code, code.contains("auth") || code.contains("invalid_client") {
                throw DreadcastError.missingCredentials("Xweather rejected the saved credentials. Run `dread auth xweather` to update them.")
            }
            throw DreadcastError.invalidResponse("Xweather")
        }
        let cutoff = now.addingTimeInterval(-1200)
        return (payload.response ?? []).compactMap { record -> LightningStrike? in
            guard let seconds = record.ob.timestampMS.map({ $0 / 1000 }) ?? record.ob.timestamp else { return nil }
            let coordinate = GeoCoordinate(latitude: record.loc.lat, longitude: record.loc.long)
            guard coordinate.isValid else { return nil }
            let kind: LightningStrike.Kind
            switch record.ob.pulse?.type?.lowercased() {
            case "cg": kind = .cloudToGround
            case "ic": kind = .intracloud
            default: kind = .unknown
            }
            return LightningStrike(id: record.id, coordinate: coordinate,
                                   timestamp: Date(timeIntervalSince1970: seconds), kind: kind,
                                   peakAmps: record.ob.pulse?.peakamp)
        }
        .filter { $0.timestamp > cutoff }
    }
}
