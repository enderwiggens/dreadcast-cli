import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum HazardKind: String, CaseIterable, Sendable, Codable {
    case tsunamis, volcanoes, smoke, radioDisruption, dust

    public var displayName: String {
        switch self {
        case .tsunamis: "Tsunamis"
        case .volcanoes: "Volcanoes"
        case .smoke: "Smoke"
        case .radioDisruption: "HF radio"
        case .dust: "Dust"
        }
    }

    public var source: String {
        switch self {
        case .tsunamis: "NTWC/PTWC"
        case .volcanoes: "USGS HANS"
        case .smoke: "NOAA HMS"
        case .radioDisruption: "NOAA SWPC D-RAP"
        case .dust: "Open-Meteo / CAMS"
        }
    }

    public var sourceURL: URL {
        switch self {
        case .tsunamis: URL(string: "https://www.tsunami.gov/")!
        case .volcanoes: URL(string: "https://www.usgs.gov/programs/VHP/volcano-updates")!
        case .smoke: URL(string: "https://www.ospo.noaa.gov/products/land/hms.html")!
        case .radioDisruption: URL(string: "https://www.swpc.noaa.gov/products/d-region-absorption-predictions-d-rap")!
        case .dust: URL(string: "https://open-meteo.com/en/docs/air-quality-api")!
        }
    }
}

public struct HazardFeature: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: HazardKind
    public let title: String
    public let summary: String
    public let level: String
    public let coordinate: GeoCoordinate?
    public let polygons: [GeoPolygon]
    public let observedAt: Date?
    public let expiresAt: Date?
}

/// A regular raster. Row zero is south; column zero is west. Missing cells are nil.
public struct HazardGrid: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public let south: Double
    public let west: Double
    public let latitudeStep: Double
    public let longitudeStep: Double
    public let values: [Double?]
    public var north: Double { south + Double(rows) * latitudeStep }
    public var east: Double { west + Double(columns) * longitudeStep }

    public var isValid: Bool {
        hasValidBounds && values.count == columns * rows && values.allSatisfy { $0 == nil || ($0!.isFinite && $0! >= 0) }
    }

    var hasValidBounds: Bool {
        columns > 0 && columns <= 720 && rows > 0 && rows <= 360 &&
        south.isFinite && west.isFinite && latitudeStep.isFinite && longitudeStep.isFinite &&
        latitudeStep > 0 && longitudeStep > 0 && south >= -90 && north <= 90.000001 &&
        west >= -180 && east <= 180.000001
    }

    /// The value of the cell containing `coordinate`, if any.
    public func value(at coordinate: GeoCoordinate) -> Double? {
        let row = Int(floor((coordinate.latitude - south) / latitudeStep))
        let column = Int(floor((coordinate.longitude - west) / longitudeStep))
        guard row >= 0, row < rows, column >= 0, column < columns else { return nil }
        return values[row * columns + column]
    }
}

public struct HazardSnapshot: Equatable, Sendable {
    public let kind: HazardKind
    public let features: [HazardFeature]
    public let grid: HazardGrid?
    public let sourceAt: Date?
    public let fetchedAt: Date
    public let note: String?
}

/// Everything `dread outlook` and `dread top` report about hazards near one place.
public struct HazardSummary: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let title: String
        public let level: String
        public let detail: String?
        public let distanceMiles: Double?
        public let observedAt: Date?
        public let expiresAt: Date?
    }

    public var fetchedAt: Date
    public var tsunamis: [Item]?
    public var elevatedVolcanoes: [Item]?
    public var smokeAtLocation: String?
    public var smokeNearbyCount: Int?
    public var smokeObservedAt: Date?
    public var radioMHz: Double?
    public var radioAt: Date?
    public var dust: Double?
    public var dustAt: Date?
    /// Sources that failed, keyed by kind, so one outage never hides the others.
    public var failures: [String: String] = [:]
}

public struct HazardService: Sendable {
    private let http: HTTPClient

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public func fetch(_ kind: HazardKind, center: GeoCoordinate, now: Date = Date()) async throws -> HazardSnapshot {
        switch kind {
        case .tsunamis:
            async let ntwc = http.data(URL(string: "https://www.tsunami.gov/events/xml/PAAQCAP.xml")!, timeout: 20, source: "NTWC")
            async let ptwc = http.data(URL(string: "https://www.tsunami.gov/events/xml/PHEBCAP.xml")!, timeout: 20, source: "PTWC")
            let results = try await [ntwc, ptwc].map { try HazardDecoder.tsunamis($0, now: now) }
            let features = results.flatMap(\.features)
            return HazardSnapshot(kind: .tsunamis, features: features, grid: nil,
                                  sourceAt: results.compactMap(\.sourceAt).max(), fetchedAt: now,
                                  note: features.isEmpty ? "No active warnings, watches or advisories in the latest NTWC/PTWC bulletins." : nil)
        case .volcanoes:
            async let status = http.data(URL(string: "https://volcanoes.usgs.gov/hans-public/api/volcano/getMonitoredVolcanoes")!, timeout: 20, source: "USGS HANS")
            async let catalog = http.data(URL(string: "https://volcanoes.usgs.gov/hans-public/api/volcano/getUSVolcanoes")!, timeout: 20, source: "USGS HANS")
            return try await HazardDecoder.volcanoes(status, catalog: catalog, now: now)
        case .smoke:
            do {
                return try HazardDecoder.smoke(try await http.data(Self.smokeURL(date: now), timeout: 25, source: "NOAA HMS"), now: now)
            } catch DreadcastError.httpStatus(let status, _) where status == 404 || status == 410 {
                // Only a missing daily file permits yesterday's analysis.
                return try HazardDecoder.smoke(try await http.data(Self.smokeURL(date: now.addingTimeInterval(-86400)), timeout: 25, source: "NOAA HMS"), now: now)
            }
        case .radioDisruption:
            let data = try await http.data(URL(string: "https://services.swpc.noaa.gov/text/drap_global_frequencies.txt")!, timeout: 20, source: "NOAA SWPC")
            return try HazardDecoder.radioDisruption(data, now: now)
        case .dust:
            let request = try Self.dustRequest(center: center, radiusMiles: 60)
            return try HazardDecoder.dust(try await http.data(request.url, timeout: 20, source: "Open-Meteo"), grid: request.grid, now: now)
        }
    }

    /// Fetches every hazard independently and summarizes them for `center`.
    public func summary(near center: GeoCoordinate, now: Date = Date()) async -> HazardSummary {
        var summary = HazardSummary(fetchedAt: now)
        await withTaskGroup(of: (HazardKind, Result<HazardSnapshot, Error>).self) { group in
            for kind in HazardKind.allCases {
                group.addTask {
                    do { return (kind, .success(try await fetch(kind, center: center, now: now))) }
                    catch { return (kind, .failure(error)) }
                }
            }
            for await (kind, result) in group {
                switch result {
                case .failure(let error):
                    summary.failures[kind.rawValue] = (error as? LocalizedError)?.errorDescription ?? "Unavailable."
                case .success(let snapshot):
                    Self.apply(snapshot, to: &summary, center: center)
                }
            }
        }
        return summary
    }

    static func apply(_ snapshot: HazardSnapshot, to summary: inout HazardSummary, center: GeoCoordinate) {
        switch snapshot.kind {
        case .tsunamis:
            summary.tsunamis = snapshot.features.map { feature in
                let inArea = feature.polygons.contains { $0.contains(center) }
                return HazardSummary.Item(title: feature.title, level: feature.level,
                                          detail: inArea ? "Your location is inside a bulletin area." : nil,
                                          distanceMiles: feature.coordinate.map { $0.distanceMiles(to: center) },
                                          observedAt: feature.observedAt, expiresAt: feature.expiresAt)
            }
        case .volcanoes:
            summary.elevatedVolcanoes = snapshot.features
                .filter { ["advisory", "watch", "warning"].contains($0.level) }
                .map { feature in
                    HazardSummary.Item(title: feature.title, level: feature.level,
                                       detail: feature.summary.components(separatedBy: "\n").first,
                                       distanceMiles: feature.coordinate.map { $0.distanceMiles(to: center) },
                                       observedAt: feature.observedAt, expiresAt: nil)
                }
                .sorted { ($0.distanceMiles ?? .infinity) < ($1.distanceMiles ?? .infinity) }
        case .smoke:
            let order = ["heavy": 3, "medium": 2, "light": 1]
            let here = snapshot.features.filter { $0.polygons.contains { $0.contains(center) } }
            summary.smokeAtLocation = here.max { (order[$0.level] ?? 0) < (order[$1.level] ?? 0) }?.level ?? "none"
            summary.smokeNearbyCount = snapshot.features.filter { feature in
                feature.polygons.contains { $0.distanceMiles(from: center) <= 100 }
            }.count
            summary.smokeObservedAt = snapshot.sourceAt
        case .radioDisruption:
            summary.radioMHz = snapshot.grid?.value(at: center)
            summary.radioAt = snapshot.sourceAt
        case .dust:
            summary.dust = snapshot.grid?.value(at: center)
            summary.dustAt = snapshot.sourceAt
        }
    }

    static func dustRequest(center: GeoCoordinate, radiusMiles: Double) throws -> (url: URL, grid: HazardGrid) {
        guard center.isValid, radiusMiles.isFinite, radiusMiles > 0 else { throw DreadcastError.invalidResponse("Open-Meteo") }
        let latitude = min(84.5, max(-84.5, center.latitude))
        let latitudeSpan = min(500, max(25, radiusMiles)) / 69.0
        let longitudeSpan = min(30, latitudeSpan / max(0.1, cos(latitude * .pi / 180)))
        let south = max(-85, latitude - latitudeSpan)
        let north = min(85, latitude + latitudeSpan)
        let west = max(-180, center.longitude - longitudeSpan)
        let east = min(180, center.longitude + longitudeSpan)
        let grid = HazardGrid(columns: 5, rows: 5, south: south, west: west,
                              latitudeStep: (north - south) / 5, longitudeStep: (east - west) / 5, values: [])
        guard grid.hasValidBounds else { throw DreadcastError.invalidResponse("Open-Meteo") }
        let coordinates = (0..<25).map { index in
            GeoCoordinate(latitude: south + (Double(index / 5) + 0.5) * grid.latitudeStep,
                          longitude: west + (Double(index % 5) + 0.5) * grid.longitudeStep)
        }
        let posix = Locale(identifier: "en_US_POSIX")
        var components = URLComponents(string: "https://air-quality-api.open-meteo.com/v1/air-quality")!
        components.queryItems = [
            .init(name: "latitude", value: coordinates.map { String(format: "%.3f", locale: posix, $0.latitude) }.joined(separator: ",")),
            .init(name: "longitude", value: coordinates.map { String(format: "%.3f", locale: posix, $0.longitude) }.joined(separator: ",")),
            .init(name: "current", value: "dust"), .init(name: "timeformat", value: "unixtime"),
            .init(name: "timezone", value: "GMT"), .init(name: "cell_selection", value: "nearest")
        ]
        return (components.url!, grid)
    }

    static func smokeURL(date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy/MM/'hms_smoke'yyyyMMdd'.kml'"
        return URL(string: "https://satepsanone.nesdis.noaa.gov/pub/FIRE/web/HMS/Smoke_Polygons/KML/" + formatter.string(from: date))!
    }
}

/// Provider-specific decoders, ported from the Dreadcast app. Invalid structures
/// fail rather than implying an empty, safe map.
public enum HazardDecoder {
    public static let maximumPayloadBytes = 8 * 1024 * 1024

    public static func tsunamis(_ data: Data, now: Date = Date()) throws -> HazardSnapshot {
        let root = try xml(data, source: "NTWC/PTWC")
        guard root.name == "alert", let identifier = root.value("identifier"),
              let sent = ISODate.parse(root.value("sent")), !isFuture(sent, now),
              let status = root.value("status"), ["Actual", "Exercise", "System", "Test", "Draft"].contains(status),
              let message = root.value("msgType"), ["Alert", "Update", "Cancel"].contains(message),
              root.value("scope") == "Public" else { throw DreadcastError.invalidResponse("NTWC/PTWC") }
        var features: [HazardFeature] = []
        if status == "Actual", ["Alert", "Update"].contains(message) {
            guard !root.children(named: "info").isEmpty else { throw DreadcastError.invalidResponse("NTWC/PTWC") }
            for (index, info) in root.children(named: "info").enumerated() {
                guard let event = info.value("event"), event.lowercased().contains("tsunami") else { throw DreadcastError.invalidResponse("NTWC/PTWC") }
                let vtec = info.children(named: "parameter").first { $0.value("valueName") == "VTEC" }?.value("value") ?? ""
                guard !vtec.contains("/T."), !vtec.contains("/E."), !vtec.contains(".CAN.") else { continue }
                let category = info.children(named: "eventCode").first { $0.value("valueName") == "TsunamiSystemCategory" }?.value("value")?.lowercased()
                let inactive = ["information", "information statement", "cancellation", "cancel"]
                if let category, inactive.contains(category) { continue }
                if category == nil, ["information", "cancellation"].contains(where: { event.lowercased().contains($0) }) { continue }
                let level = category ?? ["warning", "watch", "advisory"].first { event.lowercased().contains($0) }
                guard let level, ["warning", "watch", "advisory"].contains(level) else { throw DreadcastError.invalidResponse("NTWC/PTWC") }
                guard let expires = ISODate.parse(info.value("expires")) else { throw DreadcastError.invalidResponse("NTWC/PTWC") }
                guard expires > now else { continue }
                var coordinate: GeoCoordinate?
                if let location = info.children(named: "parameter").first(where: { $0.value("valueName") == "EventLatLon" })?.value("value"),
                   let first = location.split(whereSeparator: \.isWhitespace).first {
                    coordinate = try point(String(first), longitudeFirst: false)
                }
                let polygons = try info.children(named: "area").flatMap { area in
                    try area.children(named: "polygon").map { GeoPolygon(outerRing: try ring($0.text, longitudeFirst: false)) }
                }
                features.append(HazardFeature(id: "\(identifier)-\(index)", kind: .tsunamis,
                                              title: info.value("headline") ?? "Tsunami \(level.capitalized)",
                                              summary: [info.value("description"), info.value("instruction")].compactMap { $0 }.joined(separator: "\n\n"),
                                              level: level, coordinate: coordinate, polygons: polygons,
                                              observedAt: sent, expiresAt: expires))
            }
        }
        return HazardSnapshot(kind: .tsunamis, features: features, grid: nil, sourceAt: sent, fetchedAt: now, note: nil)
    }

    public static func volcanoes(_ data: Data, catalog: Data, now: Date = Date()) throws -> HazardSnapshot {
        struct Status: Decodable {
            let volcano_cd: String
            let vnum: String?
            let volcano_name: String
            let sent_unixtime: Double?
            let alert_level: String?
            let color_code: String?
        }
        struct Location: Decodable {
            let volcano_cd: String
            let vnum: String?
            let latitude: Double
            let longitude: Double
        }
        let rows: [Status]
        let locations: [Location]
        do {
            rows = try JSONDecoder().decode([Status].self, from: data)
            locations = try JSONDecoder().decode([Location].self, from: catalog)
        } catch {
            throw DreadcastError.invalidResponse("USGS HANS")
        }
        guard !locations.isEmpty else { throw DreadcastError.invalidResponse("USGS HANS") }
        var byCode: [String: Location] = [:]
        var byNumber: [String: Location] = [:]
        for item in locations {
            byCode[item.volcano_cd] = item
            if let number = item.vnum { byNumber[number] = item }
        }
        var features: [HazardFeature] = []
        var used = Set<String>()
        for item in rows {
            guard let number = item.vnum,
                  let location = byNumber[number] ?? byCode[item.volcano_cd],
                  GeoCoordinate(latitude: location.latitude, longitude: location.longitude).isValid,
                  used.insert(item.volcano_cd).inserted else { continue }
            let observed = item.sent_unixtime.map(Date.init(timeIntervalSince1970:))
            let raw = item.alert_level?.lowercased() ?? "unassigned"
            let level = ["normal", "advisory", "watch", "warning"].contains(raw) ? raw : "unassigned"
            let color = item.color_code.map { ["GREEN", "YELLOW", "ORANGE", "RED"].contains($0) ? $0.capitalized : "Unassigned" } ?? "Unassigned"
            features.append(HazardFeature(id: item.volcano_cd, kind: .volcanoes, title: item.volcano_name,
                                          summary: "\(level.capitalized) / \(color)", level: level,
                                          coordinate: GeoCoordinate(latitude: location.latitude, longitude: location.longitude),
                                          polygons: [], observedAt: observed, expiresAt: nil))
        }
        return HazardSnapshot(kind: .volcanoes, features: features, grid: nil,
                              sourceAt: features.compactMap(\.observedAt).max(), fetchedAt: now, note: nil)
    }

    public static func smoke(_ data: Data, now: Date = Date()) throws -> HazardSnapshot {
        let root = try xml(data, source: "NOAA HMS")
        guard root.name == "kml", let document = root.children(named: "Document").first,
              let name = document.value("name"),
              let rawDate = name.range(of: #"\d{8}$"#, options: .regularExpression),
              let analysisDate = formattedDate(String(name[rawDate]), format: "yyyyMMdd"),
              !isFuture(analysisDate, now) else { throw DreadcastError.invalidResponse("NOAA HMS") }
        var features: [HazardFeature] = []
        var ids = Set<String>()
        for placemark in document.descendants(named: "Placemark") {
            let description = placemark.value("description") ?? ""
            guard let start = smokeTime(description, label: "Start Time"),
                  let end = smokeTime(description, label: "End Time"), end >= start,
                  !isFuture(end, now) else { throw DreadcastError.invalidResponse("NOAA HMS") }
            let style = placemark.value("styleUrl")?.lowercased() ?? ""
            let level = ["light", "medium", "heavy"].first { style.contains("smoke_\($0)") } ?? "unassigned"
            let polygons = try placemark.descendants(named: "Polygon").map { polygon -> GeoPolygon in
                guard let outer = polygon.children(named: "outerBoundaryIs").first?.descendants(named: "coordinates").first else {
                    throw DreadcastError.invalidResponse("NOAA HMS")
                }
                let holes = try polygon.children(named: "innerBoundaryIs").map { inner -> [GeoCoordinate] in
                    guard let coordinates = inner.descendants(named: "coordinates").first else { throw DreadcastError.invalidResponse("NOAA HMS") }
                    return try ring(coordinates.text, longitudeFirst: true)
                }
                return GeoPolygon(outerRing: try ring(outer.text, longitudeFirst: true), holes: holes)
            }
            guard !polygons.isEmpty else { throw DreadcastError.invalidResponse("NOAA HMS") }
            // Daily files are rewritten and reordered; tie identity to the geometry.
            let identity = "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(level)|" + polygons.map { polygon in
                polygon.outerRing.map { "\($0.longitude),\($0.latitude)" }.joined(separator: ";")
            }.joined(separator: "|")
            let id = "hms-" + String(fnv1a(identity), radix: 16)
            guard ids.insert(id).inserted else { continue }
            features.append(HazardFeature(id: id, kind: .smoke, title: "\(level.capitalized) smoke",
                                          summary: "Satellite-analyzed smoke density: \(level). Not a surface air-quality measurement.",
                                          level: level, coordinate: nil, polygons: polygons, observedAt: end, expiresAt: nil))
        }
        return HazardSnapshot(kind: .smoke, features: features, grid: nil,
                              sourceAt: features.compactMap(\.observedAt).max() ?? analysisDate, fetchedAt: now, note: nil)
    }

    public static func radioDisruption(_ data: Data, now: Date = Date()) throws -> HazardSnapshot {
        guard !data.isEmpty, data.count <= maximumPayloadBytes,
              let text = String(data: data, encoding: .utf8) else { throw DreadcastError.invalidResponse("NOAA SWPC") }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let timeLine = lines.first(where: { $0.contains("Product Valid At") }),
              let timeRange = timeLine.range(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2} UTC"#, options: .regularExpression),
              let sourceAt = formattedDate(String(timeLine[timeRange]), format: "yyyy-MM-dd HH:mm 'UTC'"),
              !isFuture(sourceAt, now) else { throw DreadcastError.invalidResponse("NOAA SWPC") }
        let body = lines.filter { !$0.hasPrefix("#") && !$0.isEmpty && !Set($0).isSubset(of: ["-"]) }
        guard let header = body.first, !header.contains("|") else { throw DreadcastError.invalidResponse("NOAA SWPC") }
        let longitudeTokens = header.split(whereSeparator: \.isWhitespace)
        let longitudes = longitudeTokens.compactMap { Double($0) }
        guard longitudeTokens.count == longitudes.count, (2...720).contains(longitudes.count) else { throw DreadcastError.invalidResponse("NOAA SWPC") }
        let longitudeStep = try regularStep(longitudes)
        var rows: [(latitude: Double, values: [Double?])] = []
        for line in body.dropFirst() {
            let pieces = line.split(separator: "|", omittingEmptySubsequences: false)
            guard pieces.count == 2, let latitude = Double(pieces[0].trimmingCharacters(in: .whitespaces)),
                  (-90...90).contains(latitude) else { throw DreadcastError.invalidResponse("NOAA SWPC") }
            let values: [Double?] = try pieces[1].split(whereSeparator: \.isWhitespace).map { token in
                if ["-1", "-999", "-9999", "nan", "null", "n/a", "---"].contains(token.lowercased()) { return nil }
                guard let value = Double(token), value.isFinite, (0...100).contains(value) else { throw DreadcastError.invalidResponse("NOAA SWPC") }
                return value
            }
            guard values.count == longitudes.count else { throw DreadcastError.invalidResponse("NOAA SWPC") }
            rows.append((latitude, values))
        }
        guard (2...360).contains(rows.count) else { throw DreadcastError.invalidResponse("NOAA SWPC") }
        rows.sort { $0.latitude < $1.latitude }
        let latitudeStep = try regularStep(rows.map(\.latitude))
        let grid = HazardGrid(columns: longitudes.count, rows: rows.count,
                              south: rows[0].latitude - latitudeStep / 2, west: longitudes[0] - longitudeStep / 2,
                              latitudeStep: latitudeStep, longitudeStep: longitudeStep, values: rows.flatMap(\.values))
        guard grid.isValid else { throw DreadcastError.invalidResponse("NOAA SWPC") }
        return HazardSnapshot(kind: .radioDisruption, features: [], grid: grid, sourceAt: sourceAt, fetchedAt: now,
                              note: "Highest frequency affected by 1 dB absorption, in MHz.")
    }

    public static func dust(_ data: Data, grid: HazardGrid, now: Date = Date()) throws -> HazardSnapshot {
        struct Sample: Decodable {
            struct Units: Decodable { let dust: String }
            struct Current: Decodable { let time: Double; let dust: Double? }
            let latitude: Double
            let longitude: Double
            let current_units: Units
            let current: Current
        }
        let rows: [Sample]
        do { rows = try JSONDecoder().decode([Sample].self, from: data) }
        catch { throw DreadcastError.invalidResponse("Open-Meteo") }
        guard rows.count == grid.rows * grid.columns else { throw DreadcastError.invalidResponse("Open-Meteo") }
        var values: [Double?] = []
        var times: [Date] = []
        for row in rows {
            guard ["μg/m³", "µg/m³", "ug/m3"].contains(row.current_units.dust) else { throw DreadcastError.invalidResponse("Open-Meteo") }
            let time = Date(timeIntervalSince1970: row.current.time)
            guard row.current.time.isFinite, !isFuture(time, now) else { throw DreadcastError.invalidResponse("Open-Meteo") }
            times.append(time)
            values.append(row.current.dust.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        }
        return HazardSnapshot(kind: .dust, features: [],
                              grid: HazardGrid(columns: grid.columns, rows: grid.rows, south: grid.south, west: grid.west,
                                               latitudeStep: grid.latitudeStep, longitudeStep: grid.longitudeStep, values: values),
                              sourceAt: times.min(), fetchedAt: now, note: "Modeled dust, µg/m³.")
    }

    // MARK: Helpers

    private static func isFuture(_ date: Date, _ now: Date) -> Bool { date.timeIntervalSince(now) > 300 }

    private static func formattedDate(_ string: String, format: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        formatter.isLenient = false
        guard let result = formatter.date(from: string), formatter.string(from: result) == string else { return nil }
        return result
    }

    private static func smokeTime(_ text: String, label: String) -> Date? {
        guard let range = text.range(of: "\(label):\\s*\\d{7} \\d{4}UTC", options: .regularExpression) else { return nil }
        let value = text[range].split(separator: ":", maxSplits: 1).last!.trimmingCharacters(in: .whitespaces)
        return formattedDate(value, format: "yyyyDDD HHmm'UTC'")
    }

    private static func regularStep(_ values: [Double]) throws -> Double {
        let step = values[1] - values[0]
        guard step > 0, zip(values, values.dropFirst()).allSatisfy({ abs(($1 - $0) - step) < 0.000001 }) else {
            throw DreadcastError.invalidResponse("NOAA SWPC")
        }
        return step
    }

    private static func point(_ text: String, longitudeFirst: Bool) throws -> GeoCoordinate {
        let numbers = text.split(separator: ",", omittingEmptySubsequences: false)
        guard (2...3).contains(numbers.count), let first = Double(numbers[0]), let second = Double(numbers[1]) else {
            throw DreadcastError.invalidResponse("hazard geometry")
        }
        let coordinate = GeoCoordinate(latitude: longitudeFirst ? second : first, longitude: longitudeFirst ? first : second)
        guard coordinate.isValid else { throw DreadcastError.invalidResponse("hazard geometry") }
        return coordinate
    }

    private static func ring(_ text: String, longitudeFirst: Bool) throws -> [GeoCoordinate] {
        let points = try text.split(whereSeparator: \.isWhitespace).map { try point(String($0), longitudeFirst: longitudeFirst) }
        guard points.count >= 4, points.first == points.last else { throw DreadcastError.invalidResponse("hazard geometry") }
        return points
    }

    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    private static func xml(_ data: Data, source: String) throws -> XMLNode {
        guard !data.isEmpty, data.count <= maximumPayloadBytes,
              let text = String(data: data, encoding: .utf8),
              !text.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw DreadcastError.invalidResponse(source) }
        let delegate = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse(), !delegate.failed, let root = delegate.root else { throw DreadcastError.invalidResponse(source) }
        return root
    }

    final class XMLNode {
        let name: String
        var text = ""
        var children: [XMLNode] = []
        init(name: String) { self.name = name }
        func children(named name: String) -> [XMLNode] { children.filter { $0.name == name } }
        func value(_ name: String) -> String? {
            guard let value = children(named: name).first?.text.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func descendants(named name: String) -> [XMLNode] {
            children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(named: name) }
        }
    }

    final class XMLTreeBuilder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []
        var failed = false
        var count = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            count += 1
            guard stack.count < 48, count < 150_000 else { failed = true; parser.abortParsing(); return }
            let node = XMLNode(name: elementName)
            if let parent = stack.last { parent.children.append(node) }
            else if root == nil { root = node }
            else { failed = true; parser.abortParsing(); return }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let string = String(data: CDATABlock, encoding: .utf8) else { failed = true; parser.abortParsing(); return }
            stack.last?.text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
            failed = true
            parser.abortParsing()
            return nil
        }
    }
}
