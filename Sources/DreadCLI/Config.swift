import Foundation
import DreadcastKit

/// Saved preferences, stored as JSON in the user's config directory.
public struct Config: Codable, Sendable {
    public var version = 1
    public var location: Place?
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
    /// Show the scene as a banner above `dread` and `dread top`.
    public var sceneBanner: Bool = true

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerate missing keys so older files keep loading.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        location = try? c.decode(Place.self, forKey: .location)
        units = (try? c.decode(UnitSystem.self, forKey: .units)) ?? .imperial
        palette = (try? c.decode(RadarPalette.self, forKey: .palette)) ?? .dreadcast
        radarRange = (try? c.decode(Int.self, forKey: .radarRange)) ?? 35
        renderer = (try? c.decode(String.self, forKey: .renderer)) ?? "auto"
        quips = (try? c.decode(Bool.self, forKey: .quips)) ?? true
        icons = (try? c.decode(String.self, forKey: .icons)) ?? "emoji"
        scene = (try? c.decode(String.self, forKey: .scene)) ?? "asteroid"
        sceneBanner = (try? c.decode(Bool.self, forKey: .sceneBanner)) ?? true
        // Early builds saved `scene: off` to hide the banner.
        if scene == "off" {
            scene = "asteroid"
            sceneBanner = false
        }
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
