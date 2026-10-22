import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The radar loop from the Dreadcast API (`GET /v2/radar/latest`; dreadcast-server
/// `docs/API.md`): numeric radar tiles by region, NOAA MRMS for the US and its
/// territories and EUMETNET OPERA for Europe, in frames four minutes apart. Everything in
/// a manifest is checked by the Mac app's rules before it can become a tile request.
public struct DreadcastRadarManifest: Codable, Sendable {
    public struct Level: Codable, Sendable, Equatable {
        public let z: Int
        public let xMin: Int, xMax: Int, yMin: Int, yMax: Int
        public var tileCount: Int { (xMax - xMin + 1) * (yMax - yMin + 1) }
    }

    /// Who to credit for a region's radar.
    public struct Source: Codable, Sendable, Equatable {
        public let name: String
        /// Such as "CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)".
        public let license: String?

        /// The credit to show with the radar. A license other than the public domain is
        /// named, with a note that the data was changed: Dreadcast resamples it into tiles.
        public var credit: String {
            guard let license, !license.lowercased().hasPrefix("public domain") else { return name }
            return "\(name) (\(license.components(separatedBy: " (")[0]), resampled)"
        }
    }

    public struct Region: Codable, Sendable, Equatable {
        public let id: String
        public let name: String
        /// `[west, south, east, north]` in degrees.
        public let bounds: [Double]
        /// Zoom levels in order, ending at `maximumZoom`.
        public let levels: [Level]
        public let newestObservedAt: Date
        /// The region counts as delayed once its newest scan is this old.
        public let delayedAfter: TimeInterval
        public let delayedByServer: Bool
        public let source: Source

        public var minimumZoom: Int { levels[0].z }
        public var tileCount: Int { levels.reduce(0) { $0 + $1.tileCount } }

        public func contains(_ coordinate: GeoCoordinate) -> Bool {
            DreadcastRadarManifest.covers(coordinate, bounds: bounds)
        }

        public func isDelayed(at now: Date) -> Bool {
            delayedByServer || now.timeIntervalSince(newestObservedAt) > delayedAfter
        }

        public func isUsable(at now: Date) -> Bool {
            now.timeIntervalSince(newestObservedAt) <= DreadcastRadarManifest.unusableAfter
        }

        /// The state of tile (z, x, y) in a scan's expanded states: `t`, `n` or `m`.
        /// Tiles outside the grid are `m`.
        func state(_ states: [UInt8], z: Int, x: Int, y: Int) -> UInt8 {
            var offset = 0
            for level in levels {
                if level.z == z {
                    guard (level.xMin...level.xMax).contains(x), (level.yMin...level.yMax).contains(y) else { return DreadcastRadarManifest.m }
                    let index = offset + (x - level.xMin) * (level.yMax - level.yMin + 1) + (y - level.yMin)
                    return index < states.count ? states[index] : DreadcastRadarManifest.m
                }
                offset += level.tileCount
            }
            return DreadcastRadarManifest.m
        }
    }

    /// One region's scan: the tiles a frame draws for that region.
    public struct Scan: Codable, Sendable, Equatable {
        public let id: String
        public let observedAt: Date
        /// Tile URL with `{z}`, `{x}` and `{y}`.
        public let tileURL: String
        /// Run-length encoded tile states in grid order: `t` stored, `n` covered with no
        /// echo, `m` no coverage.
        public let tileStates: String

        func tileURL(z: Int, x: Int, y: Int) -> URL? {
            URL(string: tileURL.replacingOccurrences(of: "{z}", with: "\(z)")
                .replacingOccurrences(of: "{x}", with: "\(x)").replacingOccurrences(of: "{y}", with: "\(y)"))
        }
    }

    /// One step of the loop: each region's newest scan by the end of a four-minute window.
    public struct Frame: Codable, Sendable, Equatable {
        public let id: String
        public let observedAt: Date
        /// Scans by region ID. A region without one had no scan yet and draws nothing.
        public let scans: [String: Scan]
        /// The satellite blend the server pairs with the frame, by snapshot ID.
        public var satellite: Int?
    }

    /// NOAA's satellite rain estimates for where no region reaches (`satellite` in the
    /// API's manifest): 256-pixel tiles in Rainbow.ai's dbz_u8 encoding at zooms 0 to
    /// `maximumZoom`, from the radar CDN when the API names it there, else from the API
    /// itself. A blend arrives 15 to 21 minutes after its scan, so the newest frames have
    /// none of their own.
    public struct Satellite: Codable, Sendable, Equatable {
        public struct Snapshot: Codable, Sendable, Equatable {
            /// The scan's start in epoch seconds.
            public let id: Int
            public let observedAt: Date
        }

        public static let encoding = "rainbow-dbz-u8"
        public static let tileSize = 256
        public static let tilePath = "v2/radar/satellite.png?snapshot={snapshot}&z={z}&x={x}&y={y}"

        /// Newest first.
        public let snapshots: [Snapshot]
        public let maximumZoom: Int
        public let source: Source
        /// The same tiles on the radar CDN, with `{snapshot}`, `{z}`, `{x}` and `{y}`: only
        /// ever `satellite/{snapshot}/{z}/{x}/{y}.png` under the radar tiles' own checked
        /// origin. Nil keeps the API's `tilePath`.
        public var tileURL: String? = nil

        /// The CDN has tiles only for rows that reach between 70°N and 60°S.
        public static let northernmost = 70.0, southernmost = -60.0

        /// The CDN's tile, or nil to ask the API.
        func cdnURL(snapshot: Int, z: Int, x: Int, y: Int) -> URL? {
            guard let tileURL else { return nil }
            return URL(string: tileURL.replacingOccurrences(of: "{snapshot}", with: "\(snapshot)")
                .replacingOccurrences(of: "{z}", with: "\(z)").replacingOccurrences(of: "{x}", with: "\(x)")
                .replacingOccurrences(of: "{y}", with: "\(y)"))
        }

        /// Whether tile row `y` at zoom `z` reaches the satellites' latitudes at all.
        static func rowHasData(z: Int, y: Int) -> Bool {
            let n = Double(1 << z)
            func latitude(_ row: Double) -> Double { atan(sinh(.pi * (1 - 2 * row / n))) * 180 / .pi }
            return latitude(Double(y)) > southernmost && latitude(Double(y + 1)) < northernmost
        }
    }

    public static let encoding = "mrms-rg8-v1"
    public static let tileSize = 512
    public static let maximumZoom = 8
    /// A region is delayed once its newest scan is this old, unless the server gives it
    /// longer, and is no longer shown at the second limit.
    public static let delayedAfter: TimeInterval = 10 * 60
    public static let unusableAfter: TimeInterval = 3 * 60 * 60

    /// In drawing priority order.
    public let regions: [Region]
    /// Oldest first.
    public let frames: [Frame]
    public let fetchedAt: Date
    /// Satellite rain where no region reaches; nil when the API has none to offer.
    public let satellite: Satellite?

    /// The satellite blend a frame shows: the one the server pairs with it, or for the
    /// newest frames, which NOAA hasn't covered yet, the newest blend up to the frame's
    /// time, held as the Mac app holds it.
    public func satelliteSnapshot(for frame: Frame) -> Satellite.Snapshot? {
        guard let satellite else { return nil }
        if let id = frame.satellite { return satellite.snapshots.first { $0.id == id } }
        return satellite.snapshots.first { $0.observedAt <= frame.observedAt }
    }

    public static func covers(_ c: GeoCoordinate, bounds b: [Double]) -> Bool {
        b.count == 4 && c.longitude >= b[0] && c.longitude <= b[2] && c.latitude >= b[1] && c.latitude <= b[3]
    }

    /// The loop without regions too old to show, or nil when none is recent enough.
    public func usable(at now: Date) -> DreadcastRadarManifest? {
        let kept = regions.filter { $0.isUsable(at: now) }
        guard !kept.isEmpty else { return nil }
        if kept.count == regions.count { return self }
        let ids = Set(kept.map(\.id))
        var frames: [Frame] = []
        for frame in self.frames {
            let scans = frame.scans.filter { ids.contains($0.key) }
            // A frame that only the dropped regions moved on repeats the one before it.
            guard let newest = scans.values.map(\.observedAt).max(), newest > frames.last?.observedAt ?? .distantPast else { continue }
            frames.append(Frame(id: Self.frameID(prefix: "radar", for: newest), observedAt: newest, scans: scans, satellite: frame.satellite))
        }
        return frames.isEmpty ? nil : DreadcastRadarManifest(regions: kept, frames: frames, fetchedAt: fetchedAt, satellite: satellite)
    }

    /// The region a place's radar is timed by: the first around it, in drawing order,
    /// with a scan in the newest frame.
    public func region(for coordinate: GeoCoordinate) -> Region? {
        guard let newest = frames.last else { return nil }
        return regions.first { $0.contains(coordinate) && newest.scans[$0.id] != nil }
    }

    /// The loop as one region sees it: a frame for each of its scans, the latest frame
    /// holding that scan, timed by the scan. A region that skips a window repeats its
    /// scan, and a delayed region repeats its last one in every frame.
    public func frames(for region: Region) -> [Frame] {
        var result: [Frame] = []
        for frame in frames {
            guard let scan = frame.scans[region.id] else { continue }
            let timed = Frame(id: frame.id, observedAt: scan.observedAt, scans: frame.scans, satellite: frame.satellite)
            if result.last?.scans[region.id]?.id == scan.id { result[result.count - 1] = timed } else { result.append(timed) }
        }
        return result
    }

    /// Whom to credit for a view: the sources of the regions with radar in the newest
    /// frame whose bounds meet the box, in drawing order, once each.
    public func credits(south: Double, north: Double, west: Double, east: Double) -> [String] {
        guard let newest = frames.last else { return [] }
        var credits: [String] = []
        for region in regions where newest.scans[region.id] != nil {
            let b = region.bounds
            let longitudes = west <= east ? (b[0] <= east && b[2] >= west) : (b[2] >= west || b[0] <= east)
            guard longitudes, b[1] <= north, b[3] >= south, !credits.contains(region.source.credit) else { continue }
            credits.append(region.source.credit)
        }
        return credits
    }

    static let t = UInt8(ascii: "t"), n = UInt8(ascii: "n"), m = UInt8(ascii: "m")

    /// `m3t1n2` → `mmmtnn`, or nil when malformed.
    static func expand(_ encoded: String, limit: Int = 8192) -> [UInt8]? {
        var result: [UInt8] = []
        var letter: UInt8?
        var count = 0
        func flush() -> Bool {
            guard let letter, count > 0, result.count + count <= limit else { return letter == nil }
            result.append(contentsOf: repeatElement(letter, count: count))
            return true
        }
        for byte in encoded.utf8 {
            switch byte {
            case t, n, m:
                guard flush() else { return nil }
                letter = byte
                count = 0
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                guard letter != nil, count < 100_000 else { return nil }
                count = count * 10 + Int(byte - UInt8(ascii: "0"))
            default:
                return nil
            }
        }
        guard flush() else { return nil }
        return result
    }

    /// Tiles come only from the hosts Dreadcast serves them from, so a bad manifest
    /// can't point requests anywhere else. Loopback is for a local development server.
    static func isAllowedTileHost(_ host: String, allowLoopback: Bool) -> Bool {
        let host = host.lowercased()
        return host == "dreadcast.app" || host.hasSuffix(".dreadcast.app") || host.hasSuffix(".digitaloceanspaces.com")
            || (allowLoopback && (host == "127.0.0.1" || host == "localhost"))
    }

    /// The prefix and the UTC time, as the server names frames (`radar-`) and region
    /// scans (`mrms-`).
    static func frameID(prefix: String, for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return prefix + String(format: "-%04d%02d%02dt%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Text from the manifest that the terminal shows: short, and without control
    /// characters that could reach the terminal as escape sequences.
    static func isDisplayable(_ text: String, limit: Int) -> Bool {
        !text.isEmpty && text.count <= limit && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    // MARK: Decoding

    /// Nil instead of an error when a value doesn't fit, so an optional block can't fail
    /// the radar.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct Wire: Decodable {
        struct Level: Decodable { let z: Int; let x: [Int]; let y: [Int] }
        struct Source: Decodable { let name: String; let license: String? }
        struct Region: Decodable {
            let id: String
            let name: String
            let status: String
            let newestObservedAt: String
            let bounds: [Double]
            let cellDegrees: Double?
            let delayedAfterSeconds: Int?
            let minZoom: Int
            let maxZoom: Int
            let tileGrid: [Level]
            let source: Source?
        }
        struct Scan: Decodable {
            let id: String
            let observedAt: String
            let flagObservedAt: String?
            let tileUrl: String
            let tileStates: String
        }
        struct Frame: Decodable {
            let id: String
            let observedAt: String
            let regions: [String: Scan]
            let satellite: Lenient<Int>?
        }
        struct Satellite: Decodable {
            struct Snapshot: Decodable { let id: Int; let observedAt: String }
            let source: Source?
            let encoding: String
            let tileSize: Int
            let maxZoom: Int
            let tilePath: String
            let tileUrl: String?
            let snapshots: [Snapshot]
        }
        let status: String
        let newestObservedAt: String
        let encoding: String
        let tileSize: Int
        let regions: [Region]
        let frames: [Frame]
        let satellite: Lenient<Satellite>?
    }

    private init(regions: [Region], frames: [Frame], fetchedAt: Date, satellite: Satellite?) {
        self.regions = regions
        self.frames = frames
        self.fetchedAt = fetchedAt
        self.satellite = satellite
    }

    /// The satellite block, checked as the Mac app checks it, or nil when anything about
    /// it doesn't: satellite rain is left out rather than failing the radar.
    private static func satellite(_ wire: Wire.Satellite?, origin: String?) -> Satellite? {
        guard let wire, wire.encoding == Satellite.encoding, wire.tileSize == Satellite.tileSize,
              (0...8).contains(wire.maxZoom), wire.tilePath == Satellite.tilePath,
              (1...24).contains(wire.snapshots.count) else { return nil }
        var snapshots: [Satellite.Snapshot] = []
        for snapshot in wire.snapshots {
            guard snapshot.id > 0, let observed = ISODate.parse(snapshot.observedAt),
                  abs(observed.timeIntervalSince1970 - Double(snapshot.id)) < 1,
                  snapshots.last.map({ $0.id > snapshot.id }) ?? true else { return nil }
            snapshots.append(Satellite.Snapshot(id: snapshot.id, observedAt: observed))
        }
        let source = wire.source.flatMap { source -> Source? in
            guard isDisplayable(source.name, limit: 64), source.license.map({ isDisplayable($0, limit: 200) }) ?? true else { return nil }
            return Source(name: source.name, license: source.license)
        } ?? Source(name: "NOAA Enterprise Rain Rate", license: nil)
        var satellite = Satellite(snapshots: snapshots, maximumZoom: wire.maxZoom, source: source)
        // As the Mac app takes it: exactly this path under the radar tiles' origin, which
        // has already passed the host checks. Anything else keeps the API.
        if let origin, let cdn = wire.tileUrl, cdn == origin + "satellite/{snapshot}/{z}/{x}/{y}.png" {
            satellite.tileURL = cdn
        }
        return satellite
    }

    public static func decode(_ data: Data, now: Date, allowLoopback: Bool = false) throws -> DreadcastRadarManifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let wire = try? decoder.decode(Wire.self, from: data) else {
            throw DreadcastError.invalidResponse("The Dreadcast radar manifest")
        }
        func check(_ condition: Bool, _ field: String) throws {
            if !condition { throw DreadcastError.invalidResponse("The Dreadcast radar manifest (\(field))") }
        }
        func date(_ text: String, _ field: String) throws -> Date {
            guard let date = ISODate.parse(text) else { throw DreadcastError.invalidResponse("The Dreadcast radar manifest (\(field))") }
            return date
        }
        try check(wire.encoding == encoding && wire.tileSize == tileSize, "encoding")
        try check(wire.status == "live" || wire.status == "delayed", "status")
        try check((1...16).contains(wire.regions.count), "regions")

        var regions: [Region] = []
        for region in wire.regions {
            try check(region.id.utf8.count <= 24 && region.id.range(of: "^[a-z]+$", options: .regularExpression) != nil
                      && !regions.contains { $0.id == region.id }, "region")
            try check(isDisplayable(region.name, limit: 64), "region name")
            try check(region.status == "live" || region.status == "delayed", "region status")
            let b = region.bounds
            try check(b.count == 4 && b.allSatisfy(\.isFinite) && b[0] >= -180 && b[2] <= 180 && b[0] < b[2]
                      && b[1] >= -85.06 && b[3] <= 85.06 && b[1] < b[3], "bounds")
            if let cell = region.cellDegrees {
                try check(cell.isFinite && cell > 0 && cell <= 1, "cell size")
            }
            if let delay = region.delayedAfterSeconds {
                try check(60 <= delay && TimeInterval(delay) < unusableAfter, "delay")
            }
            if let source = region.source {
                try check(isDisplayable(source.name, limit: 64) && source.license.map { isDisplayable($0, limit: 200) } ?? true, "source")
            }
            try check((0...maximumZoom).contains(region.minZoom) && region.maxZoom == maximumZoom, "zoom range")
            var levels: [Level] = []
            for (offset, level) in region.tileGrid.enumerated() {
                let size = 1 << max(0, min(level.z, 30))
                try check(level.z == region.minZoom + offset && level.x.count == 2 && level.y.count == 2
                          && 0 <= level.x[0] && level.x[0] <= level.x[1] && level.x[1] < size
                          && 0 <= level.y[0] && level.y[0] <= level.y[1] && level.y[1] < size, "tile grid")
                levels.append(Level(z: level.z, xMin: level.x[0], xMax: level.x[1], yMin: level.y[0], yMax: level.y[1]))
            }
            try check(levels.count == region.maxZoom - region.minZoom + 1, "tile grid")
            try check(levels.reduce(0) { $0 + $1.tileCount } <= 8192, "tile grid")
            regions.append(Region(id: region.id, name: region.name, bounds: b, levels: levels,
                                  newestObservedAt: try date(region.newestObservedAt, "region time"),
                                  delayedAfter: region.delayedAfterSeconds.map(TimeInterval.init) ?? delayedAfter,
                                  delayedByServer: region.status == "delayed",
                                  source: region.source.map { Source(name: $0.name, license: $0.license) } ?? Source(name: "Dreadcast", license: nil)))
        }

        // An hour is 15 frames; the app's longest loops are 16.
        try check((1...16).contains(wire.frames.count), "frames")
        var frames: [Frame] = []
        var origin: String?
        for frame in wire.frames {
            let observed = try date(frame.observedAt, "frame time")
            try check(frame.id == frameID(prefix: "radar", for: observed), "frame id")
            try check(frames.last.map { $0.observedAt < observed } ?? true, "frame order")
            try check(!frame.regions.isEmpty, "frame regions")
            var scans: [String: Scan] = [:]
            for (regionID, scan) in frame.regions {
                guard let region = regions.first(where: { $0.id == regionID }) else { throw DreadcastError.invalidResponse("The Dreadcast radar manifest (frame regions)") }
                let scanned = try date(scan.observedAt, "scan time")
                try check(scan.id == frameID(prefix: "mrms", for: scanned), "scan id")
                try check(scanned <= observed && scanned <= region.newestObservedAt, "scan time")
                if let flag = scan.flagObservedAt {
                    let flagged = try date(flag, "flag time")
                    try check(abs(flagged.timeIntervalSince(scanned)) <= 120, "flag time")
                }
                try check(expand(scan.tileStates)?.count == region.tileCount, "tile states")
                let suffix = "snapshots/\(scan.id)/\(regionID)/{z}/{x}/{y}.png"
                try check(scan.tileUrl.hasSuffix(suffix), "tile url")
                let base = String(scan.tileUrl.dropLast(suffix.count))
                guard let url = URL(string: base), let host = url.host, url.user == nil, url.password == nil,
                      url.query == nil, url.fragment == nil,
                      url.scheme == "https" || (allowLoopback && url.scheme == "http"),
                      isAllowedTileHost(host, allowLoopback: allowLoopback),
                      origin == nil || origin == base else { throw DreadcastError.invalidResponse("The Dreadcast radar manifest (tile url)") }
                origin = base
                scans[regionID] = Scan(id: scan.id, observedAt: scanned, tileURL: scan.tileUrl, tileStates: scan.tileStates)
            }
            try check(scans.values.map(\.observedAt).max() == observed, "frame time")
            frames.append(Frame(id: frame.id, observedAt: observed, scans: scans, satellite: frame.satellite?.value))
        }
        let newest = regions.map(\.newestObservedAt).max()
        try check(ISODate.parse(wire.newestObservedAt) == newest && frames.last?.observedAt == newest, "newest observation")

        // A frame names only blends the block lists; without the block, none.
        let satellite = Self.satellite(wire.satellite?.value, origin: origin)
        let listed = Set(satellite?.snapshots.map(\.id) ?? [])
        frames = frames.map { frame in
            var frame = frame
            if let id = frame.satellite, !listed.contains(id) { frame.satellite = nil }
            return frame
        }
        return DreadcastRadarManifest(regions: regions, frames: frames, fetchedAt: now, satellite: satellite)
    }
}

/// Fetches the radar manifest from a Dreadcast API base URL.
public struct DreadcastRadarService: Sendable {
    private let http: HTTPClient
    public let baseURL: URL

    public init(http: HTTPClient = HTTPClient(), baseURL: URL) {
        self.http = http
        self.baseURL = baseURL
    }

    /// Loopback base URLs are a local development server, whose tiles are local too.
    public var allowsLoopback: Bool { ["127.0.0.1", "localhost"].contains(baseURL.host?.lowercased() ?? "") }

    /// How far back the loop reaches, in minutes: the hour the app shows everyone, up to
    /// 15 frames four minutes apart (dreadcast-server `docs/API.md#longer-loops`). Without
    /// `minutes` the API serves half an hour.
    public static let loopMinutes = 60

    public func latest(now: Date = Date()) async throws -> DreadcastRadarManifest {
        let path = baseURL.appendingPathComponent("v2/radar/latest")
        var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "minutes", value: String(Self.loopMinutes))]
        let url = components?.url ?? path
        let data: Data
        do {
            data = try await http.data(url, accept: "application/json", timeout: 15, maximumBytes: 1024 * 1024, source: "The Dreadcast API")
        } catch DreadcastError.httpStatus(503, _) {
            throw DreadcastError.unavailable("Dreadcast radar is unavailable right now")
        }
        return try DreadcastRadarManifest.decode(data, now: now, allowLoopback: allowsLoopback)
    }
}

extension RadarTileDecoder {
    /// No radar coverage, in an MRMS tile's reflectivity. It never reaches a field: the
    /// field records it as uncovered.
    static let uncovered = Int8.min + 1

    /// An MRMS numeric tile: red 0 is no coverage, 1 covered with no echo, and 2–255
    /// reflectivity as dBZ = (R − 2) / 2 − 32. Green is NOAA's precipitation type, where
    /// 3 is snow; Europe has none, and its green is always 255.
    static func decodeMRMSTile(_ image: RGBAImage) -> Tile {
        let count = image.width * image.height
        var dbz = [Int8](repeating: ReflectivityField.none, count: count)
        var snow = [Bool](repeating: false, count: count)
        image.pixels.withUnsafeBufferPointer { p in
            for i in 0..<count {
                let red = p[i * 4]
                guard red >= 2 else {
                    if red == 0 { dbz[i] = uncovered }
                    continue
                }
                let value = (Double(red) - 2) / 2 - 32
                dbz[i] = Int8(max(-127, min(127, value.rounded())))
                snow[i] = p[i * 4 + 1] == 3
            }
        }
        return Tile(size: image.width, dbz: dbz, snow: snow)
    }

    /// Tiles the API lists instead of storing: covered with no echo (`n`), and no
    /// coverage (`m`).
    static let emptyMRMSTile = constantMRMSTile(ReflectivityField.none)
    static let uncoveredMRMSTile = constantMRMSTile(uncovered)

    private static func constantMRMSTile(_ value: Int8) -> Tile {
        let count = DreadcastRadarManifest.tileSize * DreadcastRadarManifest.tileSize
        return Tile(size: DreadcastRadarManifest.tileSize, dbz: [Int8](repeating: value, count: count), snow: [Bool](repeating: false, count: count))
    }
}

extension RadarTileDecoder.Tile {
    /// Where regions overlap, each pixel comes from the first region with coverage
    /// there: this tile, with its uncovered pixels taken from a later region's.
    func filling(from later: Self) -> Self {
        guard later.size == size else { return self }
        var dbz = self.dbz, snow = self.snow
        for i in dbz.indices where dbz[i] == RadarTileDecoder.uncovered {
            dbz[i] = later.dbz[i]
            snow[i] = later.snow[i]
        }
        return Self(size: size, dbz: dbz, snow: snow)
    }

    var isFullyCovered: Bool { !dbz.contains(RadarTileDecoder.uncovered) }
}
