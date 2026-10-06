import Foundation

/// A WGS84 coordinate in decimal degrees.
public struct GeoCoordinate: Equatable, Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    /// Rounded to two decimal places (about 1 km). dreadcast stores and sends
    /// only coarsened coordinates.
    public var coarsened: GeoCoordinate {
        GeoCoordinate(latitude: (latitude * 100).rounded() / 100, longitude: (longitude * 100).rounded() / 100)
    }

    public static let earthRadiusMiles = 3958.8

    /// Great-circle distance in statute miles.
    public func distanceMiles(to other: GeoCoordinate) -> Double {
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (other.longitude - longitude) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * Self.earthRadiusMiles * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }

    /// Initial great-circle bearing from this point toward `other`, 0–360° clockwise from north.
    public func bearingDegrees(to other: GeoCoordinate) -> Double {
        let lat1 = latitude * .pi / 180, lat2 = other.latitude * .pi / 180
        let dLon = (other.longitude - longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// A small-distance offset using a local flat approximation.
    public func offset(milesEast: Double, milesNorth: Double) -> GeoCoordinate {
        let latitudeDelta = milesNorth / 69.0
        let longitudeDelta = milesEast / (69.0 * max(0.05, cos(latitude * .pi / 180)))
        return GeoCoordinate(latitude: latitude + latitudeDelta, longitude: longitude + longitudeDelta)
    }

    /// Local east/north offset of `other` in miles, using a flat approximation.
    public func milesTo(_ other: GeoCoordinate) -> (east: Double, north: Double) {
        let north = (other.latitude - latitude) * 69.0
        var dLon = other.longitude - longitude
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        let east = dLon * 69.0 * max(0.05, cos(latitude * .pi / 180))
        return (east, north)
    }

    public var formatted: String {
        String(format: "%.2f, %.2f", locale: Locale(identifier: "en_US_POSIX"), latitude, longitude)
            .replacingOccurrences(of: "-", with: "−")
    }
}

public enum Compass {
    private static let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                                 "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
    private static let words = ["north", "north-northeast", "northeast", "east-northeast",
                                "east", "east-southeast", "southeast", "south-southeast",
                                "south", "south-southwest", "southwest", "west-southwest",
                                "west", "west-northwest", "northwest", "north-northwest"]

    /// Sixteen-point compass abbreviation for a bearing in degrees.
    public static func point(_ degrees: Double) -> String {
        points[index(degrees)]
    }

    public static func word(_ degrees: Double) -> String {
        words[index(degrees)]
    }

    /// Eight-point compass abbreviation.
    public static func octant(_ degrees: Double) -> String {
        ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][Int(((normalized(degrees) + 22.5) / 45).rounded(.down)) % 8]
    }

    private static func index(_ degrees: Double) -> Int {
        Int(((normalized(degrees) + 11.25) / 22.5).rounded(.down)) % 16
    }

    private static func normalized(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}

public struct GeoPolygon: Equatable, Sendable {
    public let outerRing: [GeoCoordinate]
    public let holes: [[GeoCoordinate]]

    public init(outerRing: [GeoCoordinate], holes: [[GeoCoordinate]] = []) {
        self.outerRing = outerRing
        self.holes = holes
    }

    public var representativeCoordinate: GeoCoordinate? {
        guard let first = outerRing.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for point in outerRing.dropFirst() {
            minLat = min(minLat, point.latitude); maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude); maxLon = max(maxLon, point.longitude)
        }
        return GeoCoordinate(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
    }

    /// Even-odd containment, holes excluded.
    public func contains(_ point: GeoCoordinate) -> Bool {
        guard Self.ring(outerRing, contains: point) else { return false }
        return !holes.contains { Self.ring($0, contains: point) }
    }

    public static func ring(_ ring: [GeoCoordinate], contains point: GeoCoordinate) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude) {
                let x = (b.longitude - a.longitude) * (point.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude
                if point.longitude < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Approximate distance in miles from `point` to the nearest polygon vertex,
    /// or zero when the point is inside.
    public func distanceMiles(from point: GeoCoordinate) -> Double {
        if contains(point) { return 0 }
        return outerRing.map { $0.distanceMiles(to: point) }.min() ?? .infinity
    }
}

public struct GeoLine: Equatable, Sendable {
    public let coordinates: [GeoCoordinate]

    public init(coordinates: [GeoCoordinate]) {
        self.coordinates = coordinates
    }
}
