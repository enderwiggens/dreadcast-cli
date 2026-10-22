import Foundation

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
    /// Which pixels have radar coverage, from sources that say; nil when a source
    /// doesn't, which counts everything as covered.
    public var covered: [Bool]?
    /// When satellite estimates fill pixels no radar reaches: the blend's time.
    public var estimatedAt: Date?
    /// Which pixels hold satellite estimates rather than radar; nil when none do.
    public var estimated: [Bool]?
    /// Which pixels hold model rain, a forecast rather than an observation; nil when none do.
    public var modeled: [Bool]?

    public init(width: Int, height: Int, time: Date, dbz: [Int8], snow: [Bool], covered: [Bool]? = nil, estimatedAt: Date? = nil) {
        self.width = width
        self.height = height
        self.time = time
        self.dbz = dbz
        self.snow = snow
        self.covered = covered
        self.estimatedAt = estimatedAt
    }

    /// Takes `other`'s pixels wherever this field has no coverage and `other` does, as
    /// satellite estimates fill in beyond the radar, and marks them `estimated`. Returns
    /// whether any pixel came from it. Both fields must be the same size and record
    /// coverage.
    public mutating func fill(from other: ReflectivityField) -> Bool {
        guard var covered, let theirs = other.covered, other.width == width, other.height == height else { return false }
        var estimated = self.estimated ?? [Bool](repeating: false, count: covered.count)
        var modeled = self.modeled ?? [Bool](repeating: false, count: covered.count)
        var filled = false, anyModel = self.modeled != nil
        for i in covered.indices where !covered[i] && theirs[i] {
            covered[i] = true
            estimated[i] = true
            dbz[i] = other.dbz[i]
            snow[i] = other.snow[i]
            if other.modeled?[i] == true {
                modeled[i] = true
                anyModel = true
            }
            filled = true
        }
        self.covered = covered
        if filled { self.estimated = estimated }
        if anyModel { self.modeled = modeled }
        return filled
    }

    /// Some pixel with an echo shows model rain.
    public var hasModelRain: Bool {
        guard let modeled else { return false }
        return modeled.indices.contains { modeled[$0] && dbz[$0] != Self.none }
    }

    /// Some pixel has radar rather than a satellite estimate.
    public var hasAnyRadar: Bool {
        guard let covered else { return true }
        return covered.indices.contains { covered[$0] && !(estimated?[$0] ?? false) }
    }

    /// Radar, not a satellite estimate, covers the pixel.
    public func hasRadar(x: Int, y: Int) -> Bool {
        guard isCovered(x: x, y: y) else { return false }
        guard let estimated, x >= 0, y >= 0, x < width, y < height else { return true }
        return !estimated[y * width + x]
    }

    /// Whether radar covers pixel (x, y), as far as the source says.
    public func isCovered(x: Int, y: Int) -> Bool {
        guard let covered, x >= 0, y >= 0, x < width, y < height else { return covered == nil }
        return covered[y * width + x]
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

/// Turns radar tiles into reflectivity: the API's numeric MRMS and OPERA tiles (see
/// DreadcastRadar.swift) and NOAA's satellite estimates in Rainbow.ai's dbz_u8 encoding.
public enum RadarTileDecoder {
    struct Tile: Sendable {
        let size: Int
        let dbz: [Int8]
        let snow: [Bool]
        /// Pixels of model rain, in satellite tiles asked for with it.
        var model: [Bool]? = nil
    }

    /// dbz_u8's code for dry ground, −20 dBZ: the satellite blend's "no echo".
    static let dryCode: UInt8 = 12

    /// A satellite estimate tile in dbz_u8: red holds (R & 127) − 32 dBZ and R & 128
    /// marks snow. Alpha 0 is no data, which counts as no coverage. In a tile asked for
    /// with model rain, a covered pixel whose blue is 0 is rain only the model shows.
    static func decodeSatelliteTile(_ image: RGBAImage, modelRain: Bool = false) -> Tile {
        let count = image.width * image.height
        var dbz = [Int8](repeating: uncovered, count: count)
        var snow = [Bool](repeating: false, count: count)
        var model = [Bool](repeating: false, count: modelRain ? count : 0)
        var anyModel = false
        image.pixels.withUnsafeBufferPointer { p in
            for i in 0..<count where p[i * 4 + 3] != 0 {
                let code = p[i * 4] & 127
                dbz[i] = code <= dryCode ? ReflectivityField.none : Int8(Int(code) - 32)
                snow[i] = p[i * 4] & 128 != 0
                if modelRain, p[i * 4 + 3] == 255, p[i * 4 + 2] == 0, code > dryCode {
                    model[i] = true
                    anyModel = true
                }
            }
        }
        return Tile(size: image.width, dbz: dbz, snow: snow, model: anyModel ? model : nil)
    }

    /// A satellite tile the API answered 204 for: covered, and dry throughout.
    static let drySatelliteTile = constantSatelliteTile(ReflectivityField.none)
    /// A satellite tile where the satellites have no data, as past 70°N and 60°S.
    static let uncoveredSatelliteTile = constantSatelliteTile(uncovered)

    private static func constantSatelliteTile(_ value: Int8) -> Tile {
        let size = DreadcastRadarManifest.Satellite.tileSize
        return Tile(size: size, dbz: [Int8](repeating: value, count: size * size), snow: [Bool](repeating: false, count: size * size))
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

    public init(http: HTTPClient = HTTPClient(), store: (any RadarTileStore)? = nil) {
        self.http = http
        self.store = store
    }

    /// The lowest zoom whose `tileSize`-pixel tiles meet the viewport's resolution,
    /// between `minimum` and `maximum`; closer views stretch the deepest tiles.
    static func zoom(for viewport: RadarViewport, tileSize: Int, minimum: Int = 0, maximum: Int) -> Int {
        let circumference = 24_901.0 * max(0.05, cos(viewport.center.latitude * .pi / 180))
        let needed = circumference / (Double(tileSize) * viewport.milesPerPixel)
        let zoom = Int(ceil(log2(max(1, needed))))
        return max(minimum, min(maximum, zoom))
    }

    /// The zoom for a view of Dreadcast radar: the regions' tiles stop at zoom 8, and
    /// closer views sample zoom 8.
    public func dreadcastZoom(for viewport: RadarViewport, minimum: Int = 0) -> Int {
        Self.zoom(for: viewport, tileSize: DreadcastRadarManifest.tileSize, minimum: minimum, maximum: DreadcastRadarManifest.maximumZoom)
    }

    /// Whether any region's radar reaches the view in a frame: a tile there that's stored
    /// or covered with no echo. Nothing is loaded.
    public func radarReaches(_ manifest: DreadcastRadarManifest, frame: DreadcastRadarManifest.Frame, viewport: RadarViewport) -> Bool {
        let z = dreadcastZoom(for: viewport, minimum: manifest.regions.map(\.minimumZoom).min() ?? 0)
        let size = DreadcastRadarManifest.tileSize, tiles = 1 << z
        func tile(_ x: Double, _ y: Double) -> (x: Int, y: Int) {
            let p = WebMercator.pixel(viewport.coordinate(x: x, y: y), zoom: z, tileSize: size)
            return (Int(floor(p.x / Double(size))), Int(floor(p.y / Double(size))))
        }
        let middle = (x: Double(viewport.width) / 2, y: Double(viewport.height) / 2)
        let west = tile(0, middle.y).x, east = tile(Double(viewport.width - 1), middle.y).x
        let north = max(0, tile(middle.x, 0).y), south = min(tiles - 1, tile(middle.x, Double(viewport.height - 1)).y)
        guard west <= east, north <= south else { return false }
        for region in manifest.regions {
            guard let scan = frame.scans[region.id], let states = DreadcastRadarManifest.expand(scan.tileStates) else { continue }
            for x in west...east {
                for y in north...south {
                    let state = region.state(states, z: z, x: ((x % tiles) + tiles) % tiles, y: y)
                    if state == DreadcastRadarManifest.t || state == DreadcastRadarManifest.n { return true }
                }
            }
        }
        return false
    }

    /// One frame from the Dreadcast API. Regions are drawn together as the API describes:
    /// each pixel comes from the first region, in drawing order, with coverage there.
    /// Only stored (`t`) tiles are requested; listed tiles with no echo or no coverage are
    /// filled in without a request. With `satellite`, the API's base URL, NOAA's
    /// satellite estimates fill the pixels no region covers, from the frame's blend; if
    /// they can't load, the regions are drawn alone. With `modelRain`, a blend the API
    /// has model rain for adds it where the satellites see none.
    public func field(dreadcast manifest: DreadcastRadarManifest, frame: DreadcastRadarManifest.Frame,
                      viewport: RadarViewport, satellite api: URL? = nil, modelRain: Bool = false) async throws -> ReflectivityField {
        var field = try await regionField(manifest, frame: frame, viewport: viewport)
        guard let api, let satellite = manifest.satellite, let snapshot = manifest.satelliteSnapshot(for: frame),
              field.covered?.contains(false) == true,
              let estimates = try? await satelliteField(api: api, satellite: satellite, snapshot: snapshot,
                                                        viewport: viewport, time: frame.observedAt,
                                                        modelRain: modelRain) else { return field }
        if field.fill(from: estimates) { field.estimatedAt = snapshot.observedAt }
        return field
    }

    private func regionField(_ manifest: DreadcastRadarManifest, frame: DreadcastRadarManifest.Frame,
                             viewport: RadarViewport) async throws -> ReflectivityField {
        let http = self.http, store = self.store
        let layers = manifest.regions.compactMap { region -> (DreadcastRadarManifest.Region, DreadcastRadarManifest.Scan, [UInt8])? in
            guard let scan = frame.scans[region.id], let states = DreadcastRadarManifest.expand(scan.tileStates) else { return nil }
            return (region, scan, states)
        }
        let zoom = dreadcastZoom(for: viewport, minimum: manifest.regions.map(\.minimumZoom).min() ?? 0)
        return try await sample(viewport: viewport, zoom: zoom, time: frame.observedAt, coverage: true,
                                tileSize: DreadcastRadarManifest.tileSize) { z, x, y in
            var tile: RadarTileDecoder.Tile?
            for (region, scan, states) in layers {
                let next: RadarTileDecoder.Tile
                switch region.state(states, z: z, x: x, y: y) {
                case DreadcastRadarManifest.t:
                    guard let url = scan.tileURL(z: z, x: x, y: y) else { continue }
                    // A scan's tiles never change, and a region repeats a scan across frames.
                    let cacheKey = "\(scan.id)-\(region.id)-\(z)-\(x)-\(y)"
                    let data: Data
                    if let cached = store?.tileData(for: cacheKey) {
                        data = cached
                    } else {
                        data = try await http.data(url, accept: "image/png", timeout: 15, maximumBytes: 2 * 1024 * 1024,
                                                   source: "\(region.source.name) tiles")
                        store?.storeTile(data, for: cacheKey)
                    }
                    let image = try PNGDecoder.decode(data)
                    guard image.width == DreadcastRadarManifest.tileSize, image.height == DreadcastRadarManifest.tileSize else { continue }
                    next = RadarTileDecoder.decodeMRMSTile(image)
                case DreadcastRadarManifest.n:
                    next = RadarTileDecoder.emptyMRMSTile
                default:
                    continue
                }
                tile = tile?.filling(from: next) ?? next
                if tile?.isFullyCovered == true { break }
            }
            return tile ?? RadarTileDecoder.uncoveredMRMSTile
        }
    }

    /// A blend of NOAA's satellite estimates over the viewport, from the radar CDN when the
    /// API names it there, and from the API itself otherwise or when the CDN fails. With
    /// `modelRain`, a blend the API has model rain for comes from its second set of tiles.
    private func satelliteField(api: URL, satellite: DreadcastRadarManifest.Satellite,
                                snapshot: DreadcastRadarManifest.Satellite.Snapshot,
                                viewport: RadarViewport, time: Date, modelRain: Bool = false) async throws -> ReflectivityField {
        let http = self.http, store = self.store, size = DreadcastRadarManifest.Satellite.tileSize
        let zoom = Self.zoom(for: viewport, tileSize: size, maximum: satellite.maximumZoom)
        let endpoint = api.appendingPathComponent("v2/radar/satellite.png")
        let model = modelRain && satellite.hasModelRain(snapshot.id)
        return try await sample(viewport: viewport, zoom: zoom, time: time, coverage: true, tileSize: size) { z, x, y in
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            components?.queryItems = [("snapshot", snapshot.id), ("z", z), ("x", x), ("y", y)].map { URLQueryItem(name: $0.0, value: String($0.1)) }
                + (model ? [URLQueryItem(name: "model", value: "gfs")] : [])
            guard let url = components?.url else { return nil }
            // A blend's tiles never change; its model rain tiles are a set of their own.
            let cacheKey = "satellite-\(model ? "gfs-" : "")\(snapshot.id)-\(z)-\(x)-\(y)"
            let cdnURL = model ? satellite.modelCDNURL(snapshot: snapshot.id, z: z, x: x, y: y)
                : satellite.cdnURL(snapshot: snapshot.id, z: z, x: x, y: y)
            let data: Data
            if let cached = store?.tileData(for: cacheKey) {
                data = cached
            } else if let cdn = cdnURL {
                // The CDN has no tiles for rows wholly past 70°N or 60°S: no data there.
                guard DreadcastRadarManifest.Satellite.rowHasData(z: z, y: y) else { return RadarTileDecoder.uncoveredSatelliteTile }
                if let tile = try? await http.data(cdn, accept: "image/png", timeout: 15, maximumBytes: 1024 * 1024,
                                                    source: "\(satellite.source.name) tiles") {
                    data = tile
                } else {
                    data = try await http.data(url, accept: "image/png", timeout: 15, maximumBytes: 1024 * 1024, source: "The Dreadcast API")
                }
                store?.storeTile(data, for: cacheKey)
            } else {
                data = try await http.data(url, accept: "image/png", timeout: 15, maximumBytes: 1024 * 1024, source: "The Dreadcast API")
                store?.storeTile(data, for: cacheKey)
            }
            // The API answers 204, with no body, for a tile that's dry throughout; the CDN
            // serves an opaque tile of −20 dBZ instead.
            guard !data.isEmpty else { return RadarTileDecoder.drySatelliteTile }
            let image = try PNGDecoder.decode(data)
            guard image.width == size, image.height == size else { return nil }
            return RadarTileDecoder.decodeSatelliteTile(image, modelRain: model)
        }
    }

    /// Satellite estimates alone, one field per blend at the blend's own time, oldest
    /// first, for views no region reaches. Blends that fail are skipped.
    public func fields(satellite: DreadcastRadarManifest.Satellite, snapshots: [DreadcastRadarManifest.Satellite.Snapshot],
                       api: URL, viewport: RadarViewport, modelRain: Bool = false) async -> [ReflectivityField] {
        await withTaskGroup(of: ReflectivityField?.self) { group in
            for snapshot in snapshots {
                group.addTask {
                    guard var field = try? await satelliteField(api: api, satellite: satellite, snapshot: snapshot,
                                                                viewport: viewport, time: snapshot.observedAt,
                                                                modelRain: modelRain) else { return nil }
                    field.estimatedAt = snapshot.observedAt
                    field.estimated = field.covered
                    return field
                }
            }
            var result: [ReflectivityField] = []
            for await field in group { if let field { result.append(field) } }
            return result.sorted { $0.time < $1.time }
        }
    }

    /// Several frames from the Dreadcast API, oldest first. Frames that fail are skipped.
    public func fields(dreadcast manifest: DreadcastRadarManifest, frames: some Sequence<DreadcastRadarManifest.Frame> & Sendable,
                       viewport: RadarViewport, satellite api: URL? = nil, modelRain: Bool = false) async -> [ReflectivityField] {
        await withTaskGroup(of: ReflectivityField?.self) { group in
            for frame in frames {
                group.addTask { try? await field(dreadcast: manifest, frame: frame, viewport: viewport, satellite: api, modelRain: modelRain) }
            }
            var result: [ReflectivityField] = []
            for await field in group { if let field { result.append(field) } }
            return result.sorted { $0.time < $1.time }
        }
    }

    /// Samples `tileSize`-pixel tiles at `zoom` onto the viewport. `tile` loads one tile
    /// by (z, x, y), with x already wrapped around the world. With `coverage`, tiles mark
    /// pixels without coverage, and the field records which pixels are covered.
    private func sample(viewport: RadarViewport, zoom z: Int, time: Date, coverage: Bool = false, tileSize: Int,
                        tile: @escaping @Sendable (Int, Int, Int) async throws -> RadarTileDecoder.Tile?) async throws -> ReflectivityField {
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

        var decoded: [String: RadarTileDecoder.Tile] = [:]
        try await withThrowingTaskGroup(of: (String, RadarTileDecoder.Tile?).self) { group in
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
        var covered = [Bool](repeating: false, count: coverage ? viewport.width * viewport.height : 0)
        let anyModel = decoded.values.contains { $0.model != nil }
        var modeled = [Bool](repeating: false, count: anyModel ? viewport.width * viewport.height : 0)
        let columnTile = columnPixel.map { Int(floor($0 / Double(tileSize))) }
        let columnOffset = columnPixel.map { min(tileSize - 1, max(0, Int($0) - Int(floor($0 / Double(tileSize))) * tileSize)) }
        for y in 0..<viewport.height {
            let ty = Int(floor(rowPixel[y] / Double(tileSize)))
            let oy = min(tileSize - 1, max(0, Int(rowPixel[y]) - ty * tileSize))
            for x in 0..<viewport.width {
                guard let tile = decoded["\(columnTile[x]),\(ty)"] else { continue }
                let source = oy * tileSize + columnOffset[x]
                let target = y * viewport.width + x
                let value = tile.dbz[source]
                if coverage {
                    guard value != RadarTileDecoder.uncovered else { continue }
                    covered[target] = true
                }
                dbz[target] = value
                snow[target] = tile.snow[source]
                if let model = tile.model, model[source] { modeled[target] = true }
            }
        }
        var field = ReflectivityField(width: viewport.width, height: viewport.height, time: time, dbz: dbz, snow: snow,
                                      covered: coverage ? covered : nil)
        if anyModel { field.modeled = modeled }
        return field
    }
}
