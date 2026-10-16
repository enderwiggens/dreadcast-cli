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

    /// A person at the terminal, without --pretty, --plain or --json asking for printed
    /// output: the app can take over the screen.
    var interactive: Bool {
        mode == .pretty && !arguments.has("pretty") && terminal.isInputTTY && terminal.isOutputTTY
    }

    /// Plain `dread` opens the app when a person is at the terminal; piped, or with
    /// --pretty, --plain or --json, it prints the quick look instead.
    var opensApp: Bool {
        !arguments.commandGiven && !arguments.has("all") && interactive
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

    // MARK: Radar

    /// The Dreadcast API: DREADCAST_API_URL, then `dread config set api-url`, then the
    /// built-in default. "off" turns it off.
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

    /// Why there's no radar when the API is turned off.
    static let apiOff = "Radar comes from the Dreadcast API, which `api-url off` turns off"

    public func dreadcastRadar(_ api: URL) async -> Fetched<DreadcastRadarManifest> {
        let http = self.http, now = self.now
        return await load(key: "dreadcast-radar-v3-\(api.host ?? "api")", maxAge: 60, staleLimit: 7200) {
            try await DreadcastRadarService(http: http, baseURL: api).latest(now: now)
        }
    }

    /// A radar loop and where it came from.
    public struct RadarLoop: Sendable {
        public let fields: [ReflectivityField]
        /// Whom to credit, such as "NOAA MRMS". It names a license that asks for it, as
        /// in "EUMETNET OPERA (CC BY 4.0, resampled)", and the satellite blend's time
        /// when its estimates fill in beside radar, as in "NOAA Enterprise Rain Rate,
        /// 11:20 PM".
        public let credit: String
        /// The place's radar is late; show the loop with its age.
        public let delayed: Bool
        /// The newest frame's identity, to notice when another arrives.
        public let newestFrame: String?
        /// Radar covers the place itself in the newest frame.
        public let coversPlace: Bool
    }

    /// The last `count` frames for a place, at least `spacing` seconds apart, from the
    /// Dreadcast API: each region's radar where it reaches, and with `satellite`, NOAA's
    /// satellite estimates beyond. The place's region times the loop; elsewhere the
    /// loop follows the API's frames. A view no region's radar reaches loops the
    /// satellite blends themselves, at their own times.
    public func radarLoop(for place: Place, viewport: RadarViewport, frames count: Int, spacing: TimeInterval = 0,
                          satellite: Bool = true) async throws -> RadarLoop {
        guard let api = dreadcastAPI else { throw DreadcastError.unavailable(Self.apiOff) }
        let fetched = await dreadcastRadar(api)
        guard let manifest = fetched.value?.usable(at: now) else {
            throw DreadcastError.unavailable(fetched.error ?? "Radar is unavailable right now")
        }
        let loader = RadarLoader(http: http, store: tiles)
        func satelliteLoop() async throws -> RadarLoop? {
            guard satellite, let estimates = manifest.satellite else { return nil }
            let snapshots = Self.pick(estimates.snapshots.reversed(), time: \.observedAt, count: count, spacing: spacing)
            let fields = await loader.fields(satellite: estimates, snapshots: snapshots, api: api, viewport: viewport)
            guard fields.count >= min(2, count) else {
                throw DreadcastError.unavailable("Satellite rain estimates are unavailable right now")
            }
            return RadarLoop(fields: fields, credit: "\(estimates.source.credit) (satellite estimates)", delayed: false,
                             newestFrame: Self.identity(manifest), coversPlace: false)
        }
        // No region lists a tile in view, so nothing needs loading to know.
        if let last = manifest.frames.last, !loader.radarReaches(manifest, frame: last, viewport: viewport),
           let loop = try await satelliteLoop() {
            return loop
        }
        let region = manifest.region(for: place.coordinate)
        let timeline = region.map { manifest.frames(for: $0) } ?? manifest.frames
        let frames = Self.pick(timeline, time: \.observedAt, count: count, spacing: spacing)
        let center = (x: viewport.width / 2, y: viewport.height / 2)
        // The newest frame first: without satellite estimates the loop is for rain timing,
        // which needs radar at the place, and without it the rest needn't load.
        guard let last = frames.last,
              let newest = try? await loader.field(dreadcast: manifest, frame: last, viewport: viewport, satellite: satellite ? api : nil) else {
            throw DreadcastError.unavailable("Radar frames are unavailable right now")
        }
        if !satellite, region == nil || !newest.hasRadar(x: center.x, y: center.y) {
            return RadarLoop(fields: [newest], credit: "No radar here", delayed: false, newestFrame: Self.identity(manifest), coversPlace: false)
        }
        let fields = await loader.fields(dreadcast: manifest, frames: frames.dropLast(), viewport: viewport,
                                         satellite: satellite ? api : nil) + [newest]
        guard fields.count >= min(2, count) else {
            throw DreadcastError.unavailable("Radar frames are unavailable right now")
        }
        // A region's tiles can be in view while its radars reach none of the view's
        // pixels, as around Rome; then the blends loop at their own times.
        if !newest.hasAnyRadar, let loop = try? await satelliteLoop() {
            return loop
        }
        let box = viewport.boundingBox
        var credits = manifest.credits(south: box.south, north: box.north, west: box.west, east: box.east)
        if let estimated = newest.estimatedAt ?? fields.compactMap(\.estimatedAt).last {
            let zone = timeZone(for: place)
            let time = Formatter(units: units, timeZone: zone).time(estimated)
            credits.append("\(manifest.satellite?.source.credit ?? "NOAA"), \(time)")
        }
        let covers = region != nil && newest.hasRadar(x: center.x, y: center.y)
        return RadarLoop(fields: fields, credit: credits.isEmpty ? "No radar here" : credits.joined(separator: " · "),
                         delayed: region?.isDelayed(at: now) ?? false, newestFrame: Self.identity(manifest),
                         coversPlace: covers)
    }

    /// The newest frame's identity from the API, without loading tiles, to compare with
    /// a loop's `newestFrame`.
    public func newestRadarFrame() async -> String? {
        guard let api = dreadcastAPI, let manifest = await dreadcastRadar(api).value?.usable(at: now) else { return nil }
        return Self.identity(manifest)
    }

    /// The newest frame and satellite blend. A frame can gain a late scan or its blend
    /// under the same ID, so its scans and blend are part of it.
    static func identity(_ manifest: DreadcastRadarManifest) -> String? {
        manifest.frames.last.map { frame in
            [frame.id, frame.scans.values.map(\.id).sorted().joined(separator: ","), frame.satellite.map(String.init) ?? "",
             manifest.satellite?.snapshots.first.map { String($0.id) } ?? ""].joined(separator: "|")
        }
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
    /// Why there's no rain timing beyond the radar regions.
    public static let noRadarHere = "No radar reaches this place"
    /// Where radar reaches, for messages about places it doesn't.
    public static let radarCoverage = "Radar reaches the US, Puerto Rico, Guam and most of Europe."

    /// Where a place's rain timing is cached. Version 2 is radar-only, so a nowcast from
    /// RainViewer, which earlier versions used, is never read back.
    public static func nowcastKey(_ place: Place) -> String { "nowcast-v2-\(placeKey(place))" }

    /// Rain timing from radar motion. It uses radar only: satellite estimates are too
    /// coarse and too late to time rain by. A place no radar reaches gets
    /// `outsideCoverage`, which isn't a failure.
    public func nowcast(_ place: Place) async -> Fetched<Nowcast> {
        guard dreadcastAPI != nil else { return .failure(Self.apiOff) }
        let key = Self.nowcastKey(place)
        if let cached = cache.read(Nowcast.self, key: key),
           let latest = cached.value.latestFrame,
           now.timeIntervalSince(cached.storedAt) < 300,
           now.timeIntervalSince(latest) < 900 {
            return Fetched(value: cached.value, storedAt: cached.storedAt, error: nil, isStale: false)
        }
        let viewport = RadarViewport(center: place.coordinate, rangeMiles: Self.nowcastRangeMiles,
                                     width: Self.nowcastViewportSize, height: Self.nowcastViewportSize)
        // Four frames at least five minutes apart give the motion: Europe's are five
        // minutes apart, and the US's about four, so every other one.
        let loop: RadarLoop
        do {
            loop = try await radarLoop(for: place, viewport: viewport, frames: 4, spacing: 300, satellite: false)
        } catch {
            if let cached = cache.read(Nowcast.self, key: key) {
                return Fetched(value: cached.value, storedAt: cached.storedAt, error: "Radar frames are unavailable.", isStale: true)
            }
            return .failure("Radar frames are unavailable.")
        }
        guard loop.coversPlace else { return .outsideCoverage(Self.noRadarHere) }
        guard loop.fields.count >= 2 else { return .failure("Radar frames are unavailable.") }
        var result = Nowcaster.forecast(fields: loop.fields, viewport: viewport, now: now)
        result.source = loop.credit
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
