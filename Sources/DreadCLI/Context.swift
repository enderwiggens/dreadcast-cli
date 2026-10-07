import Foundation
import DreadcastKit
import DreadTerminal

public enum ExitCode: Int32, Sendable {
    case ok = 0
    /// `--fail-on`: an alert at or above the requested level is active.
    case alertActive = 1
    case usage = 2
    /// Data was unavailable or stale. Never reported as all clear.
    case unavailable = 3
    case setupRequired = 4
}

public enum OutputMode: Sendable { case pretty, plain, json }

/// Everything a command needs: arguments, preferences, terminal, cache and data loaders.
public final class Context: @unchecked Sendable {
    public let arguments: Arguments
    public let environment: [String: String]
    public let paths: Paths
    public var config: Config
    public let terminal: TerminalInfo
    public let styler: Styler
    public let mode: OutputMode
    public let http: HTTPClient
    public let cache: DiskCache
    /// Created on first use so fast commands like `prompt` skip the tile directory.
    public lazy var tiles = DiskTileStore(directory: paths.cacheDirectory.appendingPathComponent("radar", isDirectory: true))
    private let clockLock = NSLock()
    private var clock: Date
    /// The time for this run. Background fetches read it while the app's loop advances it.
    public var now: Date { clockLock.withLock { clock } }

    public init(arguments: Arguments,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                terminal: TerminalInfo? = nil,
                http: HTTPClient = HTTPClient(),
                now: Date = Date()) {
        self.arguments = arguments
        self.environment = environment
        paths = Paths.resolve(environment: environment)
        config = ConfigStore.load(from: paths)
        let detected = terminal ?? TerminalInfo.detect(environment: environment)
        self.terminal = detected
        if arguments.has("json") {
            mode = .json
        } else if arguments.has("pretty") {
            mode = .pretty
        } else if arguments.has("plain") || !detected.isOutputTTY {
            mode = .plain
        } else {
            mode = .pretty
        }
        // --pretty keeps colors when output is piped, for `less -R` and screenshots.
        let available = detected.isOutputTTY ? detected.colorMode : TerminalInfo.colorMode(environment: environment, isTTY: true)
        let colors: ColorMode = (arguments.has("no-color") || mode != .pretty) ? .none : available
        styler = Styler(mode: colors)
        self.http = http
        cache = DiskCache(directory: paths.cacheDirectory)
        self.clock = now
    }

    public func refreshClock() { clockLock.withLock { clock = Date() } }

    // MARK: Preferences

    public var units: UnitSystem {
        switch arguments.value("units")?.lowercased() {
        case "metric", "c", "celsius": .metric
        case "imperial", "f", "fahrenheit": .imperial
        default: config.units
        }
    }

    public var useEmoji: Bool {
        !arguments.has("ascii") && config.icons != "ascii" && mode == .pretty
    }

    public func icon(_ code: Int?, isDay: Bool = true) -> String {
        useEmoji ? WeatherCondition.emoji(code, isDay: isDay) : WeatherCondition.ascii(code, isDay: isDay)
    }

    /// Set while the app is running: its header already names the place.
    var inApp = false

    /// A section title, followed by the place outside the app.
    func title(_ name: String, place: Place) -> String {
        "  " + styler.paint(name, Theme.porcelain, bold: true) + (inApp ? "" : styler.paint("  ·  ", Theme.faint) + place.name)
    }

    /// Plain `dread` opens the app when a person is at the terminal; piped, or with
    /// --pretty, --plain or --json, it prints the quick look instead.
    var opensApp: Bool {
        !arguments.commandGiven && mode == .pretty && !arguments.has("pretty") && !arguments.has("all")
            && terminal.isInputTTY && terminal.isOutputTTY
    }

    public var quipsEnabled: Bool { config.quips && !arguments.has("no-quip") && mode == .pretty }

    // MARK: Output

    /// Collects output instead of writing it, for tests.
    public final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var out = "", err = ""
        public init() {}
        public var text: String { lock.withLock { out } }
        public var errors: String { lock.withLock { err } }
        func append(_ text: String, error: Bool) { lock.withLock { if error { err += text } else { out += text } } }
    }

    /// When set, output goes here instead of standard output and standard error.
    public var output: OutputBuffer?

    func emit(_ text: String) {
        if let output { output.append(text, error: false) } else { Console.write(text) }
    }

    func emitError(_ text: String) {
        if let output { output.append(text, error: true) } else { Console.writeError(text) }
    }

    public func write(_ lines: [String]) {
        emit(lines.joined(separator: "\n") + "\n")
    }

    public func write(_ line: String) {
        emit(line + "\n")
    }

    public func writeJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder.dreadcast
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return }
        emit(text + "\n")
    }

    public func fail(_ message: String, code: ExitCode) -> ExitCode {
        if mode == .json {
            struct ErrorBody: Encodable { let error: String; let code: Int32 }
            writeJSON(ErrorBody(error: message, code: code.rawValue))
        } else {
            emitError(styler.paint("dread: ", Theme.faint) + message + "\n")
        }
        return code
    }

    // MARK: Location

    public enum LocationError: LocalizedError {
        case notConfigured

        public var errorDescription: String? {
            "No location yet. Run `dread setup`, or pass --location with a ZIP code, place or lat,lon."
        }
    }

    public func resolveLocation() async throws -> Place {
        if let query = arguments.value("location") ?? environment["DREADCAST_LOCATION"], !query.isEmpty {
            // A saved place's name wins over a search.
            if let i = PlaceBook.index(of: query, in: config.places) { return config.places[i].place }
            let key = "place-" + query.lowercased()
            if let cached = cache.read(Place.self, key: key), now.timeIntervalSince(cached.storedAt) < 30 * 86400 {
                return cached.value
            }
            let places = try await PlaceService(http: http).resolve(query)
            guard let place = places.first else { throw DreadcastError.notFound("No places matched “\(query)”.") }
            cache.write(place, key: key, at: now)
            return place
        }
        guard let place = config.location else { throw LocationError.notConfigured }
        return place
    }

    /// The location's own time zone: from the forecast when cached, then the place, then this Mac.
    public func timeZone(for place: Place) -> TimeZone {
        if let report = cache.read(WeatherReport.self, key: "weather-\(Self.placeKey(place))-\(units.rawValue)")?.value {
            return report.timeZone
        }
        return place.timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    // MARK: Data, cached with per-source refresh intervals

    func load<T: Codable & Sendable>(key: String, maxAge: TimeInterval, staleLimit: TimeInterval = 6 * 3600,
                                     fetch: @Sendable () async throws -> T) async -> Fetched<T> {
        let cached = cache.read(T.self, key: key)
        if let cached, now.timeIntervalSince(cached.storedAt) >= 0, now.timeIntervalSince(cached.storedAt) < maxAge {
            return Fetched(value: cached.value, storedAt: cached.storedAt, error: nil, isStale: false)
        }
        do {
            let value = try await fetch()
            cache.write(value, key: key, at: now)
            return Fetched(value: value, storedAt: now, error: nil, isStale: false)
        } catch {
            if let cached, now.timeIntervalSince(cached.storedAt) < staleLimit {
                return Fetched(value: cached.value, storedAt: cached.storedAt, error: error.userMessage, isStale: true)
            }
            return .failure(error.userMessage)
        }
    }

    /// Cached value only, without touching the network.
    func cached<T: Codable & Sendable>(_ type: T.Type, key: String) -> (value: T, storedAt: Date)? {
        cache.read(type, key: key)
    }

    static func placeKey(_ place: Place) -> String {
        String(format: "%.2f_%.2f", locale: Locale(identifier: "en_US_POSIX"), place.coordinate.latitude, place.coordinate.longitude)
    }

    public func weather(_ place: Place) async -> Fetched<WeatherReport> {
        let units = self.units, http = self.http, now = self.now
        return await load(key: "weather-\(Self.placeKey(place))-\(units.rawValue)", maxAge: 600) {
            try await WeatherService(http: http).report(at: place.coordinate, units: units, now: now)
        }
    }

    public func alerts(_ place: Place) async -> Fetched<[WeatherAlert]> {
        guard place.isUnitedStates else {
            return .failure("NWS alerts cover the United States and its territories.")
        }
        let http = self.http
        return await load(key: "alerts-\(Self.placeKey(place))", maxAge: 120, staleLimit: 1800) {
            try await AlertService(http: http).activeAlerts(at: place.coordinate)
        }
    }

    /// Nil when no Xweather credentials are configured.
    public func lightning(_ place: Place, radiusMiles: Double = XweatherLightningService.maximumRadiusMiles) async -> Fetched<LightningSnapshot>? {
        guard let credentials = Credentials.xweather(environment: environment) else { return nil }
        let http = self.http, now = self.now
        return await load(key: "lightning-\(Self.placeKey(place))-\(Int(radiusMiles))", maxAge: 60, staleLimit: 600) {
            try await XweatherLightningService(credentials: credentials, http: http)
                .snapshot(center: place.coordinate, radiusMiles: radiusMiles, now: now)
        }
    }

    public func manifest() async -> Fetched<RadarManifest> {
        let http = self.http, now = self.now
        return await load(key: "radar-manifest", maxAge: 300, staleLimit: 3600) {
            try await RainViewerService(http: http).manifest(now: now)
        }
    }

    // MARK: Radar sources

    /// The Dreadcast API: DREADCAST_API_URL, then `dread config set api-url`, then the
    /// built-in default (none until the API is live). "off" turns it off.
    public var dreadcastAPI: URL? {
        if let raw = environment["DREADCAST_API_URL"] ?? config.apiURL {
            return Self.apiURL(raw)
        }
        return Dreadcast.apiBaseURL
    }

    /// An API base URL: HTTPS, or HTTP to a local development server.
    static func apiURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "off", var components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(), !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let loopback = host == "localhost" || host == "127.0.0.1"
        guard components.scheme == "https" || (components.scheme == "http" && loopback) else { return nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        return components.url
    }

    public enum RadarSource: Equatable, Sendable {
        case dreadcast(URL)
        case rainviewer
    }

    /// NOAA MRMS from the Dreadcast API for the contiguous US when an API is set and not
    /// turned off; RainViewer everywhere else.
    public func radarSource(for place: Place) -> RadarSource {
        guard config.radarSource != "rainviewer", let api = dreadcastAPI,
              DreadcastRadarManifest.covers(place.coordinate, bounds: DreadcastRadarManifest.contiguousUS) else { return .rainviewer }
        return .dreadcast(api)
    }

    public func dreadcastRadar(_ api: URL) async -> Fetched<DreadcastRadarManifest> {
        let http = self.http, now = self.now
        return await load(key: "dreadcast-radar-\(api.host ?? "api")", maxAge: 60, staleLimit: 7200) {
            try await DreadcastRadarService(http: http, baseURL: api).latest(now: now)
        }
    }

    /// A radar loop and where it came from.
    public struct RadarLoop: Sendable {
        public let fields: [ReflectivityField]
        /// The radar credit to show, such as "NOAA MRMS" or "RainViewer".
        public let credit: String
        /// The newest scan is late; show the loop with its age.
        public let delayed: Bool
        /// The newest frame's identity, to notice when another arrives.
        public let newestFrame: String?
    }

    /// The last `count` frames for a place, at least `spacing` seconds apart, from the
    /// place's radar source. If the Dreadcast API can't provide them, RainViewer does.
    public func radarLoop(for place: Place, viewport: RadarViewport, frames count: Int, spacing: TimeInterval = 0) async throws -> RadarLoop {
        let loader = RadarLoader(http: http, store: tiles)
        if case .dreadcast(let api) = radarSource(for: place) {
            let fetched = await dreadcastRadar(api)
            if let manifest = fetched.value, manifest.isUsable(at: now) {
                let frames = Self.pick(manifest.frames, time: \.observedAt, count: count, spacing: spacing)
                let fields = await loader.fields(dreadcast: manifest, frames: frames, viewport: viewport)
                if !fields.isEmpty {
                    return RadarLoop(fields: fields, credit: "NOAA MRMS", delayed: manifest.isDelayed(at: now), newestFrame: manifest.frames.last?.id)
                }
            }
        }
        let manifest = await self.manifest()
        guard let radar = manifest.value else { throw DreadcastError.unavailable(manifest.error ?? "Radar is unavailable.") }
        let frames = Self.pick(radar.frames, time: \.time, count: count, spacing: spacing)
        let fields = await loader.fields(manifest: radar, frames: frames, viewport: viewport)
        guard !fields.isEmpty else { throw DreadcastError.unavailable("Radar frames are unavailable right now.") }
        return RadarLoop(fields: fields, credit: "RainViewer", delayed: false, newestFrame: radar.frames.last?.path)
    }

    /// The newest frame's identity from a place's radar source, without loading tiles.
    public func newestRadarFrame(for place: Place) async -> String? {
        if case .dreadcast(let api) = radarSource(for: place), let manifest = await dreadcastRadar(api).value, manifest.isUsable(at: now) {
            return manifest.frames.last?.id
        }
        return await manifest().value?.frames.last?.path
    }

    /// Up to `count` items, newest first going back, each at least `spacing` apart;
    /// returned oldest first.
    static func pick<T>(_ items: [T], time: (T) -> Date, count: Int, spacing: TimeInterval) -> [T] {
        var chosen: [T] = []
        for item in items.reversed() where chosen.count < max(1, count) {
            if let last = chosen.last, time(last).timeIntervalSince(time(item)) < spacing { continue }
            chosen.append(item)
        }
        return chosen.reversed()
    }

    public static let nowcastViewportSize = 160
    public static let nowcastRangeMiles = 100.0

    public func nowcast(_ place: Place) async -> Fetched<Nowcast> {
        let key = "nowcast-\(Self.placeKey(place))"
        if let cached = cache.read(Nowcast.self, key: key),
           let latest = cached.value.latestFrame,
           now.timeIntervalSince(cached.storedAt) < 300,
           now.timeIntervalSince(latest) < 900 {
            return Fetched(value: cached.value, storedAt: cached.storedAt, error: nil, isStale: false)
        }
        let viewport = RadarViewport(center: place.coordinate, rangeMiles: Self.nowcastRangeMiles,
                                     width: Self.nowcastViewportSize, height: Self.nowcastViewportSize)
        // Four frames spread over the last half hour give the motion, whichever source:
        // RainViewer's are ten minutes apart, MRMS's about four, so every other one.
        let loop = try? await radarLoop(for: place, viewport: viewport, frames: 4, spacing: 420)
        let fields = loop?.fields ?? []
        guard fields.count >= 2 else {
            if let cached = cache.read(Nowcast.self, key: key) {
                return Fetched(value: cached.value, storedAt: cached.storedAt, error: "Radar frames are unavailable.", isStale: true)
            }
            return .failure("Radar frames are unavailable.")
        }
        var result = Nowcaster.forecast(fields: fields, viewport: viewport, now: now)
        result.source = loop?.credit
        cache.write(result, key: key, at: now)
        return Fetched(value: result, storedAt: now, error: nil, isStale: false)
    }

    public struct SevereRisk: Codable, Sendable {
        public let risk: SevereOutlook.Risk
        public let expires: Date?
    }

    public func severeRisk(_ place: Place) async -> Fetched<SevereRisk> {
        guard place.isUnitedStates else { return .failure("SPC outlooks cover the contiguous United States.") }
        let http = self.http, now = self.now
        return await load(key: "spc-\(Self.placeKey(place))", maxAge: 900) {
            let outlook = try await SevereOutlookService(http: http).day1(now: now)
            let risk = outlook.risk(at: place.coordinate)
            return SevereRisk(risk: risk.risk, expires: risk.expires)
        }
    }

    public func tropical() async -> Fetched<[TropicalStorm]> {
        let http = self.http
        return await load(key: "nhc-storms", maxAge: 900) { try await TropicalService(http: http).activeStorms() }
    }

    public func wildfires(_ place: Place, radiusMiles: Double = 100) async -> Fetched<[Wildfire]> {
        guard place.isUnitedStates else { return .failure("NIFC wildfire data covers the United States.") }
        let http = self.http
        return await load(key: "fires-\(Self.placeKey(place))-\(Int(radiusMiles))", maxAge: 300) {
            try await WildfireService(http: http).activeFires(near: place.coordinate, radiusMiles: radiusMiles)
        }
    }

    public func airQuality(_ place: Place) async -> Fetched<AirQualityReading> {
        let http = self.http, now = self.now
        return await load(key: "aqi-\(Self.placeKey(place))", maxAge: 1800) {
            try await AirQualityService(http: http).reading(at: place.coordinate, now: now)
        }
    }

    public func solar() async -> Fetched<SolarOutlook> {
        let http = self.http, now = self.now
        return await load(key: "swpc-kp", maxAge: 600) { try await OutlookService(http: http).solar(now: now) }
    }

    public func earthquakes() async -> Fetched<EarthquakeSnapshot> {
        let http = self.http, now = self.now
        return await load(key: "usgs-quakes", maxAge: 300) { try await OutlookService(http: http).earthquakes(now: now) }
    }

    public func aurora(_ place: Place) async -> Fetched<AuroraReading> {
        let http = self.http
        return await load(key: "aurora-\(Self.placeKey(place))", maxAge: 900) {
            try await OutlookService(http: http).aurora(at: place.coordinate)
        }
    }

    public func hazards(_ place: Place) async -> Fetched<HazardSummary> {
        let http = self.http, now = self.now
        return await load(key: "hazards-\(Self.placeKey(place))", maxAge: 900) {
            await HazardService(http: http).summary(near: place.coordinate, now: now)
        }
    }
}
