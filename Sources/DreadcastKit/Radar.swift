import Foundation

// MARK: - RainViewer manifest (radar outside the Dreadcast API's coverage)

public struct RadarFrame: Codable, Sendable, Equatable {
    public let time: Date
    public let path: String
}

public struct RadarManifest: Codable, Sendable {
    public let host: String
    public let frames: [RadarFrame]
    public let fetchedAt: Date

    /// The most recent `count` frames, oldest first.
}

public struct RainViewerService: Sendable {
    private let http: HTTPClient
    public static let maximumZoom = 7

    public init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    public func manifest(now: Date = Date()) async throws -> RadarManifest {
        let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json")!
        let data = try await http.data(url, accept: "application/json", timeout: 15, maximumBytes: 1024 * 1024, source: "RainViewer")
        return try Self.decodeManifest(data, now: now)
    }

    public static func decodeManifest(_ data: Data, now: Date) throws -> RadarManifest {
        struct Payload: Decodable {
            struct Radar: Decodable {
                struct Frame: Decodable { let time: Double; let path: String }
                let past: [Frame]
            }
            let host: String
            let radar: Radar
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) }
        catch { throw DreadcastError.invalidResponse("RainViewer") }
        guard let host = URL(string: payload.host), host.scheme == "https", host.host != nil,
              payload.radar.past.allSatisfy({ $0.path.hasPrefix("/v2/radar/") && !$0.path.contains("..") }) else {
            throw DreadcastError.invalidResponse("RainViewer")
        }
        let frames = payload.radar.past
            .filter { $0.time.isFinite && $0.time > 0 }
            .map { RadarFrame(time: Date(timeIntervalSince1970: $0.time), path: $0.path) }
            .sorted { $0.time < $1.time }
        guard !frames.isEmpty else { throw DreadcastError.unavailable("No recent radar frames are available.") }
        return RadarManifest(host: payload.host, frames: frames, fetchedAt: now)
    }

    /// Universal Blue (scheme 2), unsmoothed so every pixel matches the published color table.
    public static func tileURL(host: String, frame: RadarFrame, zoom: Int, x: Int, y: Int, size: Int = 512) -> URL? {
        URL(string: "\(host)\(frame.path)/\(size)/\(zoom)/\(x)/\(y)/2/0_1.png")
    }
}

// MARK: - Projection and viewport

public enum WebMercator {
    public static let maximumLatitude = 85.05112878

    /// Global pixel coordinates at `zoom` for square tiles of `tileSize` pixels.
    public static func pixel(_ coordinate: GeoCoordinate, zoom: Int, tileSize: Int) -> (x: Double, y: Double) {
        let scale = Double(tileSize) * pow(2, Double(zoom))
        let latitude = min(maximumLatitude, max(-maximumLatitude, coordinate.latitude)) * .pi / 180
        let x = (coordinate.longitude + 180) / 360 * scale
        let y = (1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2 * scale
        return (x, y)
    }
}

/// An equirectangular view centered on a location. `rangeMiles` is half the width.
public struct RadarViewport: Sendable, Equatable {
    public let center: GeoCoordinate
    public let rangeMiles: Double
    public let width: Int
    public let height: Int

    public init(center: GeoCoordinate, rangeMiles: Double, width: Int, height: Int) {
        self.center = center
        self.rangeMiles = rangeMiles
        self.width = max(2, width)
        self.height = max(2, height)
    }

    public var milesPerPixel: Double { 2 * rangeMiles / Double(width) }

    /// Coordinate at the center of output pixel (x, y).
    public func coordinate(x: Double, y: Double) -> GeoCoordinate {
        let east = (x + 0.5 - Double(width) / 2) * milesPerPixel
        let north = (Double(height) / 2 - (y + 0.5)) * milesPerPixel
        return center.offset(milesEast: east, milesNorth: north)
    }

    /// Output pixel position of `coordinate`; may fall outside the view.
    public func pixel(for coordinate: GeoCoordinate) -> (x: Double, y: Double) {
        let offset = center.milesTo(coordinate)
        return (Double(width) / 2 + offset.east / milesPerPixel - 0.5,
                Double(height) / 2 - offset.north / milesPerPixel - 0.5)
    }

    public var boundingBox: (south: Double, north: Double, west: Double, east: Double) {
        let nw = coordinate(x: -0.5, y: -0.5)
        let se = coordinate(x: Double(width) - 0.5, y: Double(height) - 0.5)
        return (se.latitude, nw.latitude, nw.longitude, se.longitude)
    }
}

// MARK: - Reflectivity

/// Reflectivity sampled onto a viewport. `Int8.min` marks no echo.
public struct ReflectivityField: Sendable {
    public static let none = Int8.min

    public let width: Int
    public let height: Int
    public let time: Date
    public var dbz: [Int8]
    public var snow: [Bool]

    public init(width: Int, height: Int, time: Date, dbz: [Int8], snow: [Bool]) {
        self.width = width
        self.height = height
        self.time = time
        self.dbz = dbz
        self.snow = snow
    }

    public func value(x: Int, y: Int) -> Int8? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let v = dbz[y * width + x]
        return v == Self.none ? nil : v
    }

    public func isSnow(x: Int, y: Int) -> Bool {
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return snow[y * width + x]
    }

    /// The strongest echo within `radius` pixels of (x, y).
    public func maximum(nearX x: Double, y: Double, radius: Int) -> Int8? {
        let cx = Int(x.rounded()), cy = Int(y.rounded())
        var best: Int8?
        for dy in -radius...radius {
            for dx in -radius...radius where dx * dx + dy * dy <= radius * radius {
                if let v = value(x: cx + dx, y: cy + dy), v > (best ?? Int8.min) { best = v }
            }
        }
        return best
    }
}

/// Converts RainViewer Universal Blue pixels back to reflectivity.
public enum UniversalBlueDecoder {
    struct Entry: Sendable { let dbz: Int8; let snow: Bool }

    static let lookup: [UInt32: Entry] = {
        var table: [UInt32: Entry] = [:]
        for (isSnow, colors) in [(false, RainViewerColorTable.rain), (true, RainViewerColorTable.snow)] {
            for (index, rgba) in colors.enumerated() where rgba & 0xFF != 0 {
                let dbz = Int8(index + RainViewerColorTable.minimumDBZ)
                // Repeated colors keep the lowest reflectivity they represent.
                if table[rgba] == nil { table[rgba] = Entry(dbz: dbz, snow: isSnow) }
            }
        }
        return table
    }()

    /// Reflectivity for one RGBA pixel, or nil for transparent and unknown colors.
    public static func reflectivity(rgba: UInt32) -> (dbz: Int8, snow: Bool)? {
        guard rgba & 0xFF != 0, let entry = lookup[rgba] else { return nil }
        return (entry.dbz, entry.snow)
    }

    /// The display color for a dBZ value in RainViewer's own scheme.
    public static func color(dbz: Double, snow: Bool) -> UInt32 {
        let index = max(0, min(127, Int(dbz.rounded()) - RainViewerColorTable.minimumDBZ))
        return snow ? RainViewerColorTable.snow[index] : RainViewerColorTable.rain[index]
    }

    struct Tile: Sendable {
        let size: Int
        let dbz: [Int8]
        let snow: [Bool]
    }

    static func decodeTile(_ image: RGBAImage) -> Tile {
        var dbz = [Int8](repeating: ReflectivityField.none, count: image.width * image.height)
        var snow = [Bool](repeating: false, count: image.width * image.height)
        image.pixels.withUnsafeBufferPointer { p in
            for i in 0..<(image.width * image.height) {
                let o = i * 4
                guard p[o + 3] != 0 else { continue }
                let rgba = UInt32(p[o]) << 24 | UInt32(p[o + 1]) << 16 | UInt32(p[o + 2]) << 8 | UInt32(p[o + 3])
                if let entry = lookup[rgba] {
                    dbz[i] = entry.dbz
                    snow[i] = entry.snow
                }
            }
        }
        return Tile(size: image.width, dbz: dbz, snow: snow)
    }
}

// MARK: - Loading

/// Where raw radar tiles are cached between runs. Frame paths never change, so
/// cached tiles stay valid until the frame ages out of the manifest.
public protocol RadarTileStore: Sendable {
    func tileData(for key: String) -> Data?
    func storeTile(_ data: Data, for key: String)
}

public struct RadarLoader: Sendable {
    private let http: HTTPClient
    private let store: (any RadarTileStore)?
    public let tileSize = 512

    public init(http: HTTPClient = HTTPClient(), store: (any RadarTileStore)? = nil) {
        self.http = http
        self.store = store
    }

    /// The lowest zoom whose source resolution meets the viewport's, capped at RainViewer's maximum.
    public func zoom(for viewport: RadarViewport) -> Int {
        let circumference = 24_901.0 * max(0.05, cos(viewport.center.latitude * .pi / 180))
        let needed = circumference / (Double(tileSize) * viewport.milesPerPixel)
        let zoom = Int(ceil(log2(max(1, needed))))
        return max(1, min(RainViewerService.maximumZoom, zoom))
    }

    public func field(host: String, frame: RadarFrame, viewport: RadarViewport) async throws -> ReflectivityField {
        let http = self.http, store = self.store, tileSize = self.tileSize
        return try await sample(viewport: viewport, zoom: zoom(for: viewport), time: frame.time) { z, x, y in
            guard let url = RainViewerService.tileURL(host: host, frame: frame, zoom: z, x: x, y: y, size: tileSize) else { return nil }
            let cacheKey = "\(frame.path.split(separator: "/").last ?? "frame")-\(tileSize)-\(z)-\(x)-\(y)"
            let data: Data
            if let cached = store?.tileData(for: cacheKey) {
                data = cached
            } else {
                data = try await http.data(url, accept: "image/png", timeout: 15, maximumBytes: 2 * 1024 * 1024, source: "RainViewer")
                store?.storeTile(data, for: cacheKey)
            }
            let image = try PNGDecoder.decode(data)
            guard image.width == tileSize, image.height == tileSize else { return nil }
            return UniversalBlueDecoder.decodeTile(image)
        }
    }

    /// The zoom for a Dreadcast (MRMS) view: tiles exist from zoom 3 to 8, and closer
    /// views sample zoom 8.
    public func dreadcastZoom(for viewport: RadarViewport) -> Int {
        let circumference = 24_901.0 * max(0.05, cos(viewport.center.latitude * .pi / 180))
        let needed = circumference / (Double(DreadcastRadarManifest.tileSize) * viewport.milesPerPixel)
        let zoom = Int(ceil(log2(max(1, needed))))
        return max(DreadcastRadarManifest.zooms.lowerBound, min(DreadcastRadarManifest.zooms.upperBound, zoom))
    }

    /// One MRMS frame from the Dreadcast API. Only stored (`t`) tiles are requested;
    /// listed tiles with no echo or no coverage are filled in without a request.
    public func field(dreadcast manifest: DreadcastRadarManifest, frame: DreadcastRadarManifest.Frame,
                      viewport: RadarViewport) async throws -> ReflectivityField {
        let http = self.http, store = self.store
        let states = manifest.states(for: frame)
        return try await sample(viewport: viewport, zoom: dreadcastZoom(for: viewport), time: frame.observedAt) { z, x, y in
            guard manifest.state(states, z: z, x: x, y: y) == DreadcastRadarManifest.t else { return UniversalBlueDecoder.emptyMRMSTile }
            guard let url = manifest.tileURL(frame, z: z, x: x, y: y) else { return nil }
            let cacheKey = "\(frame.id)-\(manifest.regionID)-\(z)-\(x)-\(y)"
            let data: Data
            if let cached = store?.tileData(for: cacheKey) {
                data = cached
            } else {
                data = try await http.data(url, accept: "image/png", timeout: 15, maximumBytes: 2 * 1024 * 1024, source: "NOAA MRMS tiles")
                store?.storeTile(data, for: cacheKey)
            }
            let image = try PNGDecoder.decode(data)
            guard image.width == DreadcastRadarManifest.tileSize, image.height == DreadcastRadarManifest.tileSize else { return nil }
            return UniversalBlueDecoder.decodeMRMSTile(image)
        }
    }

    /// Several MRMS frames, oldest first. Frames that fail are skipped.
    public func fields(dreadcast manifest: DreadcastRadarManifest, frames: [DreadcastRadarManifest.Frame],
                       viewport: RadarViewport) async -> [ReflectivityField] {
        await withTaskGroup(of: ReflectivityField?.self) { group in
            for frame in frames {
                group.addTask { try? await field(dreadcast: manifest, frame: frame, viewport: viewport) }
            }
            var result: [ReflectivityField] = []
            for await field in group { if let field { result.append(field) } }
            return result.sorted { $0.time < $1.time }
        }
    }

    /// Samples tiles at `zoom` onto the viewport. `tile` loads one tile by (z, x, y),
    /// with x already wrapped around the world.
    private func sample(viewport: RadarViewport, zoom z: Int, time: Date,
                        tile: @escaping @Sendable (Int, Int, Int) async throws -> UniversalBlueDecoder.Tile?) async throws -> ReflectivityField {
        let tiles = 1 << z

        // Separable mapping: latitude depends on the row, longitude on the column.
        var columnPixel = [Double](repeating: 0, count: viewport.width)
        var rowPixel = [Double](repeating: 0, count: viewport.height)
        for x in 0..<viewport.width {
            columnPixel[x] = WebMercator.pixel(viewport.coordinate(x: Double(x), y: Double(viewport.height) / 2), zoom: z, tileSize: tileSize).x
        }
        for y in 0..<viewport.height {
            rowPixel[y] = WebMercator.pixel(viewport.coordinate(x: Double(viewport.width) / 2, y: Double(y)), zoom: z, tileSize: tileSize).y
        }

        let minTileX = Int(floor(columnPixel.min()! / Double(tileSize)))
        let maxTileX = Int(floor(columnPixel.max()! / Double(tileSize)))
        let minTileY = max(0, Int(floor(rowPixel.min()! / Double(tileSize))))
        let maxTileY = min(tiles - 1, Int(floor(rowPixel.max()! / Double(tileSize))))
        guard maxTileX - minTileX < 8, maxTileY - minTileY < 8 else {
            throw DreadcastError.unavailable("The radar view is too large for one request.")
        }

        var decoded: [String: UniversalBlueDecoder.Tile] = [:]
        try await withThrowingTaskGroup(of: (String, UniversalBlueDecoder.Tile?).self) { group in
            for ty in minTileY...maxTileY {
                for tx in minTileX...maxTileX {
                    let wrapped = ((tx % tiles) + tiles) % tiles
                    group.addTask { ("\(tx),\(ty)", try await tile(z, wrapped, ty)) }
                }
            }
            for try await (key, value) in group {
                if let value { decoded[key] = value }
            }
        }
        guard !decoded.isEmpty else { throw DreadcastError.unavailable("Radar tiles are unavailable.") }

        var dbz = [Int8](repeating: ReflectivityField.none, count: viewport.width * viewport.height)
        var snow = [Bool](repeating: false, count: viewport.width * viewport.height)
        let columnTile = columnPixel.map { Int(floor($0 / Double(tileSize))) }
        let columnOffset = columnPixel.map { min(tileSize - 1, max(0, Int($0) - Int(floor($0 / Double(tileSize))) * tileSize)) }
        for y in 0..<viewport.height {
            let ty = Int(floor(rowPixel[y] / Double(tileSize)))
            let oy = min(tileSize - 1, max(0, Int(rowPixel[y]) - ty * tileSize))
            for x in 0..<viewport.width {
                guard let tile = decoded["\(columnTile[x]),\(ty)"] else { continue }
                let source = oy * tileSize + columnOffset[x]
                let target = y * viewport.width + x
                dbz[target] = tile.dbz[source]
                snow[target] = tile.snow[source]
            }
        }
        return ReflectivityField(width: viewport.width, height: viewport.height, time: time, dbz: dbz, snow: snow)
    }

    /// Loads several frames concurrently, oldest first. Frames that fail are skipped.
    public func fields(manifest: RadarManifest, frames: [RadarFrame], viewport: RadarViewport) async -> [ReflectivityField] {
        await withTaskGroup(of: ReflectivityField?.self) { group in
            for frame in frames {
                group.addTask { try? await field(host: manifest.host, frame: frame, viewport: viewport) }
            }
            var result: [ReflectivityField] = []
            for await field in group { if let field { result.append(field) } }
            return result.sorted { $0.time < $1.time }
        }
    }
}
