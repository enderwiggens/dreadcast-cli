import Foundation
import DreadcastKit

/// Saved preferences, stored as JSON in the user's config directory.
public struct Config: Codable, Sendable {
    public var version = 1
    /// Saved places; the first is the default. Older builds read only `location`.
    public var places: [SavedPlace] = []
    public var units: UnitSystem = .imperial
    public var palette: RadarPalette = .dreadcast
    public var radarRange: Int = 35
    /// auto, kitty, iterm2, halfblock or 256.
    public var renderer: String = "auto"
    /// One dry line under `dread`, never in alerts, errors or JSON.
    public var quips: Bool = true
    /// emoji or ascii weather glyphs.
    public var icons: String = "emoji"
    /// The scene for `dread scene` and the banners: a scene name, or daily to rotate.
    public var scene: String = "asteroid"
    /// Show the scene as a banner on the Now tab and above `dread now`.
    public var sceneBanner: Bool = true
    /// The accent color: auto follows the scene, as in the app, or a fixed highlight.
    public var highlight: String = "auto"
    /// The radar's basemap: theme follows the scene's map palette; graphite is neutral.
    public var map: String = "theme"
    /// Beside the radar's timeline on the Now tab: days, hourly or off.
    public var forecast: String = "days"

    /// The default place. Setting it to a saved place moves that place first; any other
    /// place replaces the default and keeps its name.
    public var location: Place? {
        get { places.first?.place }
        set {
            guard let newValue else {
                if !places.isEmpty { places.removeFirst() }
                return
            }
            if let i = places.firstIndex(where: { $0.place.coordinate == newValue.coordinate }) {
                places.insert(places.remove(at: i), at: 0)
            } else if places.isEmpty {
                places = [SavedPlace(name: "home", place: newValue)]
            } else {
                places[0].place = newValue
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, location, places, units, palette, radarRange, renderer, quips, icons, scene, sceneBanner, highlight, map, forecast
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate missing keys so older files keep loading.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        places = (try? c.decode([SavedPlace].self, forKey: .places)) ?? []
        // Files from before saved places hold only `location`; it becomes "home".
        if places.isEmpty, let legacy = try? c.decode(Place.self, forKey: .location) {
            places = [SavedPlace(name: "home", place: legacy)]
        }
        units = (try? c.decode(UnitSystem.self, forKey: .units)) ?? .imperial
        palette = (try? c.decode(RadarPalette.self, forKey: .palette)) ?? .dreadcast
        radarRange = (try? c.decode(Int.self, forKey: .radarRange)) ?? 35
        renderer = (try? c.decode(String.self, forKey: .renderer)) ?? "auto"
        quips = (try? c.decode(Bool.self, forKey: .quips)) ?? true
        icons = (try? c.decode(String.self, forKey: .icons)) ?? "emoji"
        scene = (try? c.decode(String.self, forKey: .scene)) ?? "asteroid"
        sceneBanner = (try? c.decode(Bool.self, forKey: .sceneBanner)) ?? true
        highlight = (try? c.decode(String.self, forKey: .highlight)) ?? "auto"
        map = (try? c.decode(String.self, forKey: .map)) ?? "theme"
        forecast = (try? c.decode(String.self, forKey: .forecast)) ?? "days"
        // Early builds saved `scene: off` to hide the banner.
        if scene == "off" {
            scene = "asteroid"
            sceneBanner = false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encode(places, forKey: .places)
        try c.encode(units, forKey: .units)
        try c.encode(palette, forKey: .palette)
        try c.encode(radarRange, forKey: .radarRange)
        try c.encode(renderer, forKey: .renderer)
        try c.encode(quips, forKey: .quips)
        try c.encode(icons, forKey: .icons)
        try c.encode(scene, forKey: .scene)
        try c.encode(sceneBanner, forKey: .sceneBanner)
        try c.encode(highlight, forKey: .highlight)
        try c.encode(map, forKey: .map)
        try c.encode(forecast, forKey: .forecast)
    }

    public static let ranges = [15, 35, 75, 150, 300]
}

public struct Paths: Sendable {
    public let configDirectory: URL
    public let cacheDirectory: URL

    public var configFile: URL { configDirectory.appendingPathComponent("config.json") }

    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let config: URL
        if let explicit = environment["DREADCAST_CONFIG_DIR"], !explicit.isEmpty {
            config = URL(fileURLWithPath: explicit, isDirectory: true)
        } else if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            config = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("dreadcast", isDirectory: true)
        } else {
            config = home.appendingPathComponent(".config/dreadcast", isDirectory: true)
        }
        let cache: URL
        if let explicit = environment["DREADCAST_CACHE_DIR"], !explicit.isEmpty {
            cache = URL(fileURLWithPath: explicit, isDirectory: true)
        } else if let xdg = environment["XDG_CACHE_HOME"], !xdg.isEmpty {
            cache = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("dreadcast", isDirectory: true)
        } else {
            #if os(macOS)
            cache = home.appendingPathComponent("Library/Caches/dreadcast", isDirectory: true)
            #else
            cache = home.appendingPathComponent(".cache/dreadcast", isDirectory: true)
            #endif
        }
        return Paths(configDirectory: config, cacheDirectory: cache)
    }
}

public enum ConfigStore {
    public static func load(from paths: Paths) -> Config {
        guard let data = try? Data(contentsOf: paths.configFile),
              let config = try? JSONDecoder.dreadcast.decode(Config.self, from: data) else { return Config() }
        return config
    }

    public static func save(_ config: Config, to paths: Paths) throws {
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder.dreadcast.encode(config)
        try data.write(to: paths.configFile, options: .atomic)
    }
}

extension JSONEncoder {
    static var dreadcast: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var dreadcast: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
