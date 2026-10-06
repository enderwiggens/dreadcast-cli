import Foundation

/// Natural Earth 1:50m land, lakes, borders and cities, embedded in the binary.
public final class Basemap: Sendable {
    public struct Ring: Sendable {
        public let points: [GeoCoordinate]
        public let minLatitude: Double
        public let maxLatitude: Double
        public let minLongitude: Double
        public let maxLongitude: Double

        init(points: [GeoCoordinate]) {
            self.points = points
            var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
            for p in points {
                minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
                minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
            }
            minLatitude = minLat; maxLatitude = maxLat; minLongitude = minLon; maxLongitude = maxLon
        }

        public func intersects(south: Double, north: Double, west: Double, east: Double) -> Bool {
            maxLatitude >= south && minLatitude <= north && maxLongitude >= west && minLongitude <= east
        }
    }

    public struct City: Sendable {
        public let name: String
        public let coordinate: GeoCoordinate
        /// Natural Earth scale rank: 0 is the most prominent.
        public let rank: Int
    }

    public let land: [Ring]
    public let lakes: [Ring]
    public let countryBorders: [Ring]
    public let stateBorders: [Ring]
    public let cities: [City]

    public static let shared: Basemap = {
        guard let data = Data(base64Encoded: BasemapData.base64, options: .ignoreUnknownCharacters),
              let map = try? Basemap(data: data) else {
            return Basemap(land: [], lakes: [], countryBorders: [], stateBorders: [], cities: [])
        }
        return map
    }()

    init(land: [Ring], lakes: [Ring], countryBorders: [Ring], stateBorders: [Ring], cities: [City]) {
        self.land = land
        self.lakes = lakes
        self.countryBorders = countryBorders
        self.stateBorders = stateBorders
        self.cities = cities
    }

    enum Failure: Error { case corrupt }

    convenience init(data: Data) throws {
        var reader = Reader(bytes: [UInt8](data))
        guard reader.take(4) == Array("DCB1".utf8) else { throw Failure.corrupt }
        var layers: [UInt8: [Ring]] = [:]
        let layerCount = try reader.byte()
        for _ in 0..<layerCount {
            let kind = try reader.byte()
            let ringCount = try reader.varint()
            var rings: [Ring] = []
            rings.reserveCapacity(ringCount)
            for _ in 0..<ringCount {
                let pointCount = try reader.varint()
                var points: [GeoCoordinate] = []
                points.reserveCapacity(pointCount)
                var lon = 0, lat = 0
                for _ in 0..<pointCount {
                    lon += try reader.zigzag()
                    lat += try reader.zigzag()
                    points.append(GeoCoordinate(latitude: Double(lat) / 100, longitude: Double(lon) / 100))
                }
                rings.append(Ring(points: points))
            }
            layers[kind] = rings
        }
        let cityCount = try reader.varint()
        var cities: [City] = []
        cities.reserveCapacity(cityCount)
        for _ in 0..<cityCount {
            let lon = try reader.zigzag()
            let lat = try reader.zigzag()
            let rank = Int(try reader.byte())
            let length = Int(try reader.byte())
            guard let name = String(bytes: reader.take(length), encoding: .utf8) else { throw Failure.corrupt }
            cities.append(City(name: name, coordinate: GeoCoordinate(latitude: Double(lat) / 100, longitude: Double(lon) / 100), rank: rank))
        }
        self.init(land: layers[1] ?? [], lakes: layers[2] ?? [], countryBorders: layers[3] ?? [],
                  stateBorders: layers[4] ?? [], cities: cities)
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw Failure.corrupt }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func take(_ count: Int) -> [UInt8] {
            let end = min(bytes.count, offset + count)
            defer { offset = end }
            return Array(bytes[offset..<end])
        }

        mutating func varint() throws -> Int {
            var result = 0, shift = 0
            while true {
                let b = try byte()
                result |= Int(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                guard shift < 63 else { throw Failure.corrupt }
            }
        }

        mutating func zigzag() throws -> Int {
            let value = try varint()
            return (value >> 1) ^ -(value & 1)
        }
    }

    /// Whether `coordinate` is on land (inside a land ring and outside every lake).
    public func isLand(_ coordinate: GeoCoordinate) -> Bool {
        let inLand = land.contains { ring in
            ring.intersects(south: coordinate.latitude, north: coordinate.latitude, west: coordinate.longitude, east: coordinate.longitude)
                && GeoPolygon.ring(ring.points, contains: coordinate)
        }
        guard inLand else { return false }
        return !lakes.contains { ring in
            ring.intersects(south: coordinate.latitude, north: coordinate.latitude, west: coordinate.longitude, east: coordinate.longitude)
                && GeoPolygon.ring(ring.points, contains: coordinate)
        }
    }
}
