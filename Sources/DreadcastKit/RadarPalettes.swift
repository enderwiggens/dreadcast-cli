import Foundation

/// Radar display palettes. The CLI ships the three general palettes from the
/// Dreadcast app plus RainViewer's own colors; the app's Pro palettes stay in the app.
public enum RadarPalette: String, CaseIterable, Sendable, Codable {
    case dreadcast, classic, viridis, rainviewer

    public var title: String {
        switch self {
        case .dreadcast: "Dreadcast"
        case .classic: "Classic"
        case .viridis: "Viridis"
        case .rainviewer: "RainViewer"
        }
    }

    private static let dreadcastStops: [(Double, UInt32)] = [
        (0, 0x245d79), (15, 0x449aaf), (25, 0x63c8b9), (35, 0xd6e990),
        (45, 0xffb66d), (55, 0xf26067), (65, 0xe89bc2), (80, 0xf6deed)
    ]

    private static let classicStops: [(Double, UInt32)] = [
        (0, 0x397da9), (10, 0x299ad0), (20, 0x32b64b), (30, 0xa6d43d),
        (40, 0xeeeb49), (45, 0xff922b), (55, 0xe63342), (65, 0xc356e8), (80, 0xf0d5f5)
    ]

    private static let viridisStops: [(Double, UInt32)] = ViridisSamples.rgb.enumerated().map {
        (Double($0.offset) * 80 / 255, $0.element)
    }

    /// RGB (0xRRGGBB) for a reflectivity value. Snow uses RainViewer's snow ramp
    /// only in the RainViewer palette; the others show intensity alone.
    public func rgb(dbz: Double, snow: Bool = false) -> UInt32 {
        switch self {
        case .rainviewer:
            return UniversalBlueDecoder.color(dbz: dbz, snow: snow) >> 8
        case .dreadcast:
            return Self.interpolate(Self.dreadcastStops, dbz)
        case .classic:
            return Self.interpolate(Self.classicStops, dbz)
        case .viridis:
            return Self.interpolate(Self.viridisStops, dbz)
        }
    }

    static func interpolate(_ stops: [(Double, UInt32)], _ value: Double) -> UInt32 {
        guard let first = stops.first, let last = stops.last else { return 0 }
        if value <= first.0 { return first.1 }
        if value >= last.0 { return last.1 }
        for i in 1..<stops.count where value <= stops[i].0 {
            let (z0, c0) = stops[i - 1], (z1, c1) = stops[i]
            let t = (value - z0) / (z1 - z0)
            func channel(_ shift: UInt32) -> UInt32 {
                let a = Double((c0 >> shift) & 0xFF), b = Double((c1 >> shift) & 0xFF)
                return UInt32((a + (b - a) * t).rounded()) << shift
            }
            return channel(16) | channel(8) | channel(0)
        }
        return last.1
    }
}

/// Rain-rate estimate from reflectivity using Marshall–Palmer (Z = 200 R^1.6).
public enum RainRate {
    public static func millimetersPerHour(dbz: Double) -> Double {
        guard dbz > 0 else { return 0 }
        let z = pow(10, dbz / 10)
        return pow(z / 200, 1 / 1.6)
    }

    public static func inchesPerHour(dbz: Double) -> Double { millimetersPerHour(dbz: dbz) / 25.4 }

    public enum Intensity: Int, Comparable, Sendable, Codable {
        case none, light, moderate, heavy, intense

        public init(dbz: Double) {
            switch dbz {
            case ..<20: self = .none
            case ..<30: self = .light
            case ..<40: self = .moderate
            case ..<50: self = .heavy
            default: self = .intense
            }
        }

        public var label: String {
            switch self {
            case .none: "none"
            case .light: "light"
            case .moderate: "moderate"
            case .heavy: "heavy"
            case .intense: "intense"
            }
        }

        public static func < (lhs: Intensity, rhs: Intensity) -> Bool { lhs.rawValue < rhs.rawValue }
    }
}
