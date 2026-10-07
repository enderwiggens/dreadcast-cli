import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The radar loop from the Dreadcast API (`GET /v1/radar/latest`; dreadcast-server
/// `docs/API.md`): NOAA MRMS base reflectivity for the contiguous United States, a scan
/// about every two minutes, served as numeric tiles from a CDN. Everything in a
/// manifest is validated before it can become a tile request, as in the Mac app.
public struct DreadcastRadarManifest: Codable, Sendable {
    public struct Level: Codable, Sendable, Equatable {
        public let z: Int
        public let xMin: Int, xMax: Int, yMin: Int, yMax: Int
        public var tileCount: Int { (xMax - xMin + 1) * (yMax - yMin + 1) }
    }

    public struct Frame: Codable, Sendable, Equatable {
        public let id: String
        public let observedAt: Date
        /// Tile URL with `{z}`, `{x}` and `{y}`.
        public let tileURL: String
        /// Run-length encoded tile states in grid order: `t` stored, `n` covered with no
        /// echo, `m` no coverage.
        public let tileStates: String
    }

    public static let encoding = "mrms-rg8-v1"
    public static let tileSize = 512
    public static let zooms = 3...8
    /// The loop is delayed once its newest scan is this old, and unusable at the second.
    public static let delayedAfter: TimeInterval = 10 * 60
    public static let unusableAfter: TimeInterval = 3 * 60 * 60

    public let delayedByServer: Bool
    public let newestObservedAt: Date
    public let regionID: String
    /// `[west, south, east, north]` in degrees.
    public let bounds: [Double]
    public let levels: [Level]
    public let frames: [Frame]
    public let fetchedAt: Date

    public func isDelayed(at now: Date) -> Bool {
        delayedByServer || now.timeIntervalSince(newestObservedAt) > Self.delayedAfter
    }

    public func isUsable(at now: Date) -> Bool {
        now.timeIntervalSince(newestObservedAt) <= Self.unusableAfter
    }

    /// Whether a place is inside the radar's coverage.
    public func covers(_ coordinate: GeoCoordinate) -> Bool {
        Self.covers(coordinate, bounds: bounds)
    }

    public static func covers(_ c: GeoCoordinate, bounds b: [Double]) -> Bool {
        b.count == 4 && c.longitude >= b[0] && c.longitude <= b[2] && c.latitude >= b[1] && c.latitude <= b[3]
    }

    /// The contiguous-US region the API serves today, for choosing a source before the
    /// first manifest arrives.
    public static let contiguousUS: [Double] = [-130, 20, -60, 55]

    public var radarFrames: [RadarFrame] { frames.map { RadarFrame(time: $0.observedAt, path: $0.id) } }

    /// Each tile's state for one frame, indexed in grid order.
    func states(for frame: Frame) -> [UInt8] {
        Self.expand(frame.tileStates) ?? []
    }

    /// The state of tile (z, x, y): `t`, `n` or `m`. Tiles outside the grid are `m`.
    func state(_ states: [UInt8], z: Int, x: Int, y: Int) -> UInt8 {
        var offset = 0
        for level in levels {
            if level.z == z {
                guard (level.xMin...level.xMax).contains(x), (level.yMin...level.yMax).contains(y) else { return Self.m }
                let index = offset + (x - level.xMin) * (level.yMax - level.yMin + 1) + (y - level.yMin)
                return index < states.count ? states[index] : Self.m
            }
            offset += level.tileCount
        }
        return Self.m
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

    /// The tile URL for (z, x, y) in a frame.
    func tileURL(_ frame: Frame, z: Int, x: Int, y: Int) -> URL? {
        URL(string: frame.tileURL.replacingOccurrences(of: "{z}", with: "\(z)")
            .replacingOccurrences(of: "{x}", with: "\(x)").replacingOccurrences(of: "{y}", with: "\(y)"))
    }

    /// Tiles come only from the hosts Dreadcast serves them from, so a bad manifest
    /// can't point requests anywhere else. Loopback is for a local development server.
    static func isAllowedTileHost(_ host: String, allowLoopback: Bool) -> Bool {
        let host = host.lowercased()
        return host == "dreadcast.app" || host.hasSuffix(".dreadcast.app") || host.hasSuffix(".digitaloceanspaces.com")
            || (allowLoopback && (host == "127.0.0.1" || host == "localhost"))
    }

    static func frameID(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "mrms-%04d%02d%02dt%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    // MARK: Decoding

    private struct Wire: Decodable {
        struct Region: Decodable { let id: String; let bounds: [Double] }
        struct Level: Decodable { let z: Int; let x: [Int]; let y: [Int] }
        struct Frame: Decodable {
            let id: String
            let observedAt: String
            let tileUrl: String
            let tileStates: String
        }
        let status: String
        let newestObservedAt: String
        let encoding: String
        let tileSize: Int
        let minZoom: Int
        let maxZoom: Int
        let region: Region
        let tileGrid: [Level]
        let frames: [Frame]
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
        try check(wire.encoding == encoding && wire.tileSize == tileSize && wire.minZoom == zooms.lowerBound
                  && wire.maxZoom == zooms.upperBound, "encoding")
        try check(wire.status == "live" || wire.status == "delayed", "status")
        try check(wire.region.id.utf8.count <= 24 && wire.region.id.range(of: "^[a-z]+$", options: .regularExpression) != nil, "region")
        let b = wire.region.bounds
        try check(b.count == 4 && b.allSatisfy(\.isFinite) && b[0] >= -180 && b[2] <= 180 && b[0] < b[2]
                  && b[1] >= -85.06 && b[3] <= 85.06 && b[1] < b[3], "bounds")

        var levels: [Level] = []
        for (offset, level) in wire.tileGrid.enumerated() {
            let size = 1 << max(0, min(level.z, 30))
            try check(level.z == wire.minZoom + offset && level.x.count == 2 && level.y.count == 2
                      && 0 <= level.x[0] && level.x[0] <= level.x[1] && level.x[1] < size
                      && 0 <= level.y[0] && level.y[0] <= level.y[1] && level.y[1] < size, "tile grid")
            levels.append(Level(z: level.z, xMin: level.x[0], xMax: level.x[1], yMin: level.y[0], yMax: level.y[1]))
        }
        try check(levels.count == wire.maxZoom - wire.minZoom + 1, "tile grid")
        let tileCount = levels.reduce(0) { $0 + $1.tileCount }
        try check(tileCount <= 8192, "tile grid")

        try check((1...8).contains(wire.frames.count), "frames")
        var frames: [Frame] = []
        var origin: String?
        for frame in wire.frames {
            guard let observed = ISODate.parse(frame.observedAt) else { throw DreadcastError.invalidResponse("The Dreadcast radar manifest (frame time)") }
            try check(frame.id == frameID(for: observed), "frame id")
            try check(frames.last.map { $0.observedAt < observed } ?? true, "frame order")
            try check(expand(frame.tileStates)?.count == tileCount, "tile states")
            let suffix = "snapshots/\(frame.id)/\(wire.region.id)/{z}/{x}/{y}.png"
            try check(frame.tileUrl.hasSuffix(suffix), "tile url")
            let base = String(frame.tileUrl.dropLast(suffix.count))
            guard let url = URL(string: base), let host = url.host, url.user == nil, url.password == nil,
                  url.scheme == "https" || (allowLoopback && url.scheme == "http"),
                  isAllowedTileHost(host, allowLoopback: allowLoopback),
                  origin == nil || origin == base else { throw DreadcastError.invalidResponse("The Dreadcast radar manifest (tile url)") }
            origin = base
            frames.append(Frame(id: frame.id, observedAt: observed, tileURL: frame.tileUrl, tileStates: frame.tileStates))
        }
        let newest = ISODate.parse(wire.newestObservedAt)
        try check(newest != nil && newest == frames.last?.observedAt, "newest observation")

        return DreadcastRadarManifest(delayedByServer: wire.status == "delayed", newestObservedAt: frames.last!.observedAt,
                                      regionID: wire.region.id, bounds: b, levels: levels, frames: frames, fetchedAt: now)
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

    public func latest(now: Date = Date()) async throws -> DreadcastRadarManifest {
        let url = baseURL.appendingPathComponent("v1/radar/latest")
        let data: Data
        do {
            data = try await http.data(url, accept: "application/json", timeout: 15, maximumBytes: 1024 * 1024, source: "The Dreadcast API")
        } catch DreadcastError.httpStatus(503, _) {
            throw DreadcastError.unavailable("Dreadcast radar is unavailable right now")
        }
        return try DreadcastRadarManifest.decode(data, now: now, allowLoopback: allowsLoopback)
    }
}

extension UniversalBlueDecoder {
    /// An MRMS numeric tile: red 0 is no coverage, 1 covered with no echo, and 2–255
    /// reflectivity as dBZ = (R − 2) / 2 − 32. Green is NOAA's precipitation type, where
    /// 3 is snow.
    static func decodeMRMSTile(_ image: RGBAImage) -> Tile {
        let count = image.width * image.height
        var dbz = [Int8](repeating: ReflectivityField.none, count: count)
        var snow = [Bool](repeating: false, count: count)
        image.pixels.withUnsafeBufferPointer { p in
            for i in 0..<count {
                let red = p[i * 4]
                guard red >= 2 else { continue }
                let value = (Double(red) - 2) / 2 - 32
                dbz[i] = Int8(max(-127, min(127, value.rounded())))
                snow[i] = p[i * 4 + 1] == 3
            }
        }
        return Tile(size: image.width, dbz: dbz, snow: snow)
    }

    /// A tile with no echo anywhere, for tiles the API lists instead of storing.
    static let emptyMRMSTile = Tile(size: DreadcastRadarManifest.tileSize,
                                    dbz: [Int8](repeating: ReflectivityField.none, count: DreadcastRadarManifest.tileSize * DreadcastRadarManifest.tileSize),
                                    snow: [Bool](repeating: false, count: DreadcastRadarManifest.tileSize * DreadcastRadarManifest.tileSize))
}
