import Foundation

// Minimal GeoJSON decoding shared by the NWS, SPC, NHC and NIFC services.

struct FeatureCollection<Properties: Decodable & Sendable>: Decodable, Sendable {
    struct Feature: Decodable, Sendable {
        let id: FlexibleIdentifier?
        let geometry: GeoJSONGeometry?
        let properties: Properties?
    }
    let features: [Feature]
}

struct FlexibleIdentifier: Decodable, Sendable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self.value = value }
        else if let value = try? container.decode(Int.self) { self.value = String(value) }
        else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string or integer ID")
            )
        }
    }
}

struct GeoJSONGeometry: Decodable, Sendable {
    let type: String
    let coordinates: CoordinateNode?

    var point: GeoCoordinate? {
        guard type.caseInsensitiveCompare("Point") == .orderedSame, let coordinates else { return nil }
        return Self.coordinate(from: coordinates)
    }

    var lines: [GeoLine] {
        guard let coordinates else { return [] }
        switch type.lowercased() {
        case "linestring":
            return Self.line(from: coordinates).map { [GeoLine(coordinates: $0)] } ?? []
        case "multilinestring":
            return coordinates.children.compactMap(Self.line).map(GeoLine.init)
        default:
            return []
        }
    }

    var polygons: [GeoPolygon] {
        guard let coordinates else { return [] }
        switch type.lowercased() {
        case "polygon":
            return Self.polygon(from: coordinates).map { [$0] } ?? []
        case "multipolygon":
            return coordinates.children.compactMap(Self.polygon)
        default:
            return []
        }
    }

    private static func polygon(from node: CoordinateNode) -> GeoPolygon? {
        let rings = node.children.compactMap(line)
        guard let outer = rings.first, outer.count >= 3 else { return nil }
        return GeoPolygon(outerRing: outer, holes: Array(rings.dropFirst()))
    }

    private static func line(from node: CoordinateNode) -> [GeoCoordinate]? {
        let values = node.children.compactMap(coordinate)
        return values.count >= 2 ? values : nil
    }

    private static func coordinate(from node: CoordinateNode) -> GeoCoordinate? {
        let values = node.children
        guard values.count >= 2,
              case .number(let longitude) = values[0],
              case .number(let latitude) = values[1],
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return GeoCoordinate(latitude: latitude, longitude: longitude)
    }
}

indirect enum CoordinateNode: Decodable, Sendable {
    case number(Double)
    case array([CoordinateNode])

    var children: [CoordinateNode] {
        guard case .array(let values) = self else { return [] }
        return values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .array(try container.decode([CoordinateNode].self))
        }
    }
}
