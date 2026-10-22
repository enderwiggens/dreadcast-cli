import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import DreadTerminal
@testable import DreadcastKit
@testable import DreadCLI

/// Serves canned provider responses so commands run end to end without the network.
/// Requests to hosts without a route fail as if offline.
final class StubProvider: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    /// Served for routes whose body is empty, such as PNG tiles.
    nonisolated(unsafe) static var tileBody: Data?
    /// Served instead of `tileBody` for a host and path, as "api.dreadcast.app/v2/radar/satellite.png".
    nonisolated(unsafe) static var binaries: [String: Data] = [:]
    static let lock = NSLock()

    static func reset(_ routes: [String: (Int, String)]) {
        lock.withLock {
            self.routes = routes.mapValues { (status: $0.0, body: $0.1) }
            requests = []
        }
    }

    static var seen: [URLRequest] { lock.withLock { requests } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Set once the session stops this request, as when its task is cancelled. After that
    /// the client mustn't hear from it again: on Linux, FoundationNetworking crashes when a
    /// cancelled task's protocol reports, and Swift cancels sibling requests when one fails.
    private let state = NSRecursiveLock()
    private var stopped = false

    override func startLoading() {
        state.lock()
        defer { state.unlock() }
        guard !stopped else { return }
        let url = request.url!
        // A route for the host and path wins over one for the whole host.
        let (route, binary) = Self.lock.withLock { () -> ((status: Int, body: String)?, Data?) in
            Self.requests.append(request)
            let path = (url.host ?? "") + url.path
            return (Self.routes[path] ?? Self.routes[url.host ?? ""], Self.binaries[path] ?? Self.tileBody)
        }
        guard let route else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        // A rate limit says how long to wait, as the Dreadcast API does.
        let headers = ["Content-Type": "application/json"].merging(route.status == 429 ? ["Retry-After": "120"] : [:]) { a, _ in a }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = route.status == 204 ? Data() : route.body.isEmpty ? (binary ?? Data()) : Data(route.body.utf8)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        state.lock()
        stopped = true
        state.unlock()
    }
}

/// Commands run as a person or script would run them: real argument parsing, config and
/// cache on disk, and dispatch, with providers stubbed. The suite is serialized because
/// the stub's routes are shared.
@Suite("Commands", .serialized)
struct CommandTests {
    /// The Dreadcast API's weather, by host and path.
    static let current = "api.dreadcast.app/v1/weather/current"
    static let forecast = "api.dreadcast.app/v1/weather/forecast"
    static let nws = "api.weather.gov"
    static let online: [String: (Int, String)] = [current: (200, WeatherFixture.current), forecast: (200, WeatherFixture.forecast),
                                                 nws: (200, AlertFixture.payload)]

    /// A fresh config and cache directory with an optional default place.
    static func home(location: String? = "27.947,-82.458") async throws -> [String: String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dreadcast-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let environment = ["DREADCAST_CONFIG_DIR": directory.path, "DREADCAST_CACHE_DIR": directory.appendingPathComponent("cache").path,
                           "DREADCAST_CREDENTIAL_STORE": "none"]
        if let location { _ = try await run(["setup", location, "--plain"], environment: environment, routes: [:]) }
        return environment
    }

    @discardableResult
    static func run(_ words: [String], environment: [String: String], routes: [String: (Int, String)] = online,
                    tty: Bool = false, at time: String = "2026-10-05T18:30:00Z") async throws -> (code: ExitCode, out: String, err: String) {
        StubProvider.reset(routes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProvider.self]
        let terminal = TerminalInfo(isOutputTTY: tty, isInputTTY: tty, columns: 100, rows: 40, colorMode: .none,
                                    graphics: .none, program: nil, insideMultiplexer: false, reduceMotion: false)
        let ctx = Context(arguments: try Arguments.parse(words), environment: environment, terminal: terminal,
                          http: HTTPClient(session: URLSession(configuration: configuration)),
                          now: ISODate.parse(time)!)
        let buffer = Context.OutputBuffer()
        ctx.output = buffer
        let code = await Dread.dispatch(ctx)
        return (code, buffer.text, buffer.errors)
    }

    static func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: The quick look

    /// `dread prompt` reads the conditions `dread now` cached, without the network.
    @Test func promptReadsTheCachedConditions() async throws {
        let env = try await Self.home()
        _ = try await Self.run(["now", "--plain"], environment: env)
        let prompt = try await Self.run(["prompt"], environment: env, routes: [:])
        #expect(prompt.code == .ok)
        #expect(prompt.out.contains("71°"))
        #expect(StubProvider.seen.isEmpty)
    }

    /// A 429 is waited out for as long as `Retry-After` asks, across runs, and the last
    /// reading shows meanwhile, marked stale.
    @Test func rateLimitsAreWaitedOut() async throws {
        let env = try await Self.home()
        _ = try await Self.run(["now", "--plain"], environment: env, at: "2026-10-05T18:30:00Z")
        var limited = Self.online
        limited[Self.current] = (429, #"{"error":{"code":"rate_limited","message":"Too many requests."}}"#)
        limited[Self.forecast] = limited[Self.current]
        let first = try await Self.run(["forecast", "--json"], environment: env, routes: limited, at: "2026-10-05T19:30:00Z")
        #expect(StubProvider.seen.contains { $0.url?.path == "/v1/weather/current" })
        #expect(first.out.contains("71"))
        // Within the wait, the API isn't asked again, even with it answering.
        _ = try await Self.run(["forecast", "--json"], environment: env, at: "2026-10-05T19:31:00Z")
        #expect(!StubProvider.seen.contains { $0.url?.host == "api.dreadcast.app" })
    }


    @Test func nowReportsConditionsAndAlerts() async throws {
        let env = try await Self.home()
        let plain = try await Self.run(["now", "--plain"], environment: env)
        #expect(plain.code == .ok)
        #expect(plain.out.contains("71°F"))
        #expect(plain.out.contains("Severe Thunderstorm Warning"))
        #expect(!plain.out.contains("Test Message"))

        let json = try Self.json(try await Self.run(["now", "--json"], environment: env).out)
        #expect(json["schema"] as? String == "dreadcast.now/1")
        #expect((json["alerts"] as? [Any])?.count == 2)
    }

    @Test func plainDreadPrintsTheQuickLookWhenPiped() async throws {
        let env = try await Self.home()
        let result = try await Self.run([], environment: env)
        #expect(result.code == .ok)
        #expect(result.out.contains("71°F"))
    }

    @Test func offlineIsNeverAllClear() async throws {
        let env = try await Self.home()
        let result = try await Self.run(["now", "--plain"], environment: env, routes: [:])
        #expect(result.code == .unavailable)
        #expect(!result.out.lowercased().contains("no active alerts"))
        // Alerts down while the forecast works: the quick look says so.
        let partial = try await Self.run(["now", "--plain"], environment: try await Self.home(),
                                         routes: [Self.current: (200, WeatherFixture.current), Self.forecast: (200, WeatherFixture.forecast), Self.nws: (500, "{}")])
        #expect(partial.code == .ok)
        #expect(!partial.out.lowercased().contains("no active alerts"))
        #expect(partial.out.lowercased().contains("unavailable"))
    }

    @Test func freshReadingsComeFromTheCache() async throws {
        let env = try await Self.home()
        try await Self.run(["now", "--plain"], environment: env)
        let again = try await Self.run(["now", "--plain"], environment: env, routes: [:])
        #expect(again.code == .ok)
        #expect(again.out.contains("71°F"))
        #expect(StubProvider.seen.allSatisfy { $0.url?.host != "api.dreadcast.app" && $0.url?.host != Self.nws })
    }

    // MARK: Privacy

    @Test func requestsIdentifyThemselvesAndRoundCoordinates() async throws {
        let env = try await Self.home()
        try await Self.run(["now", "--plain"], environment: env)
        let seen = StubProvider.seen
        #expect(!seen.isEmpty)
        for request in seen {
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("dreadcast-cli/") == true)
            let url = request.url!.absoluteString
            // 27.947,-82.458 is saved and sent as 27.95,-82.46.
            #expect(!url.contains("27.947") && !url.contains("82.458"))
        }
        #expect(seen.contains { $0.url!.absoluteString.contains("27.95") })
        // Weather comes from the Dreadcast API, with the rounded coordinate and the units shown.
        let weather = seen.compactMap(\.url).filter { $0.path.hasPrefix("/v1/weather/") }
        #expect(Set(weather.map(\.path)) == ["/v1/weather/current", "/v1/weather/forecast"])
        #expect(weather.allSatisfy { $0.query == "lat=27.95&lon=-82.46&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch" })
        #expect(!seen.contains { $0.url?.host?.hasSuffix("open-meteo.com") == true })
    }

    // MARK: The Dreadcast API

    /// An older reading the API serves while its provider is down is labeled stale.
    @Test func staleWeatherFromTheAPIIsLabeled() async throws {
        let env = try await Self.home()
        var routes = Self.online
        routes[Self.current] = (200, WeatherFixture.current.replacingOccurrences(of: #""stale":false"#, with: #""stale":true"#))
        let json = try Self.json(try await Self.run(["now", "--json"], environment: env, routes: routes).out)
        #expect((json["stale"] as? [String])?.contains("conditions") == true)
        #expect((json["conditions"] as? [String: Any]) != nil)
    }

    @Test func weatherInOtherUnitsThanAskedIsRefused() async throws {
        let env = try await Self.home()
        var routes = Self.online
        routes[Self.forecast] = (200, WeatherFixture.forecast.replacingOccurrences(of: #""temperature":"fahrenheit""#, with: #""temperature":"celsius""#))
        let result = try await Self.run(["forecast", "--plain"], environment: env, routes: routes)
        #expect(result.code == .unavailable)
        #expect(!result.out.contains("88°"))
    }

    /// With the API turned off there's no weather, and the commands say why without
    /// asking anyone else.
    @Test func weatherNeedsTheAPI() async throws {
        let env = try await Self.home()
        #expect(try await Self.run(["config", "set", "api-url", "off", "--plain"], environment: env).code == .ok)
        let now = try await Self.run(["now", "--plain"], environment: env)
        #expect(now.code == .unavailable && now.out.contains("api-url off"))
        #expect(!StubProvider.seen.contains { $0.url?.host == "api.dreadcast.app" || $0.url?.host?.hasSuffix("open-meteo.com") == true })
        let search = try await Self.run(["setup", "Lisbon", "--plain"], environment: env)
        #expect(search.code != .ok && search.err.contains("api-url off"))
    }

    @Test func placeSearchGoesThroughTheAPI() async throws {
        let env = try await Self.home(location: nil)
        let results = #"{"results":[{"name":"Lisbon","latitude":38.71667,"longitude":-9.13333,"country_code":"PT","country":"Portugal","admin1":"Lisbon","timezone":"Europe/Lisbon"},{"name":"Lisbon","latitude":44.03,"longitude":-70.10,"country_code":"US","country":"United States","admin1":"Maine","timezone":"America/New_York"}],"source":{"name":"Open-Meteo geocoding, from GeoNames","provider":"open-meteo","fetched_at":"2026-10-05T18:00:00Z"}}"#
        let setup = try await Self.run(["setup", "Lisbon", "--plain"], environment: env, routes: ["api.dreadcast.app/v1/places/search": (200, results)])
        #expect(setup.code == .ok)
        let search = try #require(StubProvider.seen.compactMap(\.url).first { $0.path == "/v1/places/search" })
        #expect(search.query == "q=Lisbon&count=6")
        let config = try Self.json(try await Self.run(["config", "--json"], environment: env).out)
        let saved = try #require((config["places"] as? [[String: Any]])?.first?["place"] as? [String: Any])
        #expect(saved["name"] as? String == "Lisbon, Portugal" && saved["timeZone"] as? String == "Europe/Lisbon")
        let coordinate = try #require(saved["coordinate"] as? [String: Double])
        #expect(coordinate["latitude"] == 38.72 && coordinate["longitude"] == -9.13)

        let none = try await Self.run(["setup", "Nowhereville", "--plain"], environment: env,
                                      routes: ["api.dreadcast.app/v1/places/search": (200, #"{"results":[],"source":{}}"#)])
        #expect(none.code != .ok && none.err.contains("No places matched"))
    }

    /// Air quality and dust both come from the API's point reading.
    @Test func airQualityAndDustComeFromTheAPI() async throws {
        let env = try await Self.home()
        let air = #"{"location":{"latitude":27.95,"longitude":-82.46,"timezone":"America/New_York","utc_offset_seconds":-14400},"current":{"time":"2026-10-05T18:00:00Z","interval_seconds":3600,"us_aqi":61,"pm2_5":17.2,"pm10":30.1,"ozone":80.0,"dust":142.5},"source":{"name":"Open-Meteo, with Copernicus Atmosphere Monitoring Service data","fetched_at":"2026-10-05T18:05:00Z","stale":false}}"#
        var routes = Self.online
        routes["api.dreadcast.app/v1/air/current"] = (200, air)
        StubProvider.reset(routes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProvider.self]
        let ctx = Context(arguments: Arguments(command: "outlook"), environment: env,
                          terminal: TerminalInfo(isOutputTTY: false, isInputTTY: false, columns: 100, rows: 40, colorMode: .none,
                                                 graphics: .none, program: nil, insideMultiplexer: false, reduceMotion: false),
                          http: HTTPClient(session: URLSession(configuration: configuration)), now: ISODate.parse("2026-10-05T18:30:00Z")!)
        let place = try await ctx.resolveLocation()
        let reading = try #require(await ctx.airQuality(place).value)
        #expect(reading.usAQI == 61 && reading.category == "Moderate" && reading.pm2_5 == 17.2 && reading.dust == 142.5)
        let hazards = try #require(await ctx.hazards(place).value)
        #expect(hazards.dust == 142.5 && hazards.failures["dust"] == nil)
        let requests = StubProvider.seen.compactMap(\.url).filter { $0.path == "/v1/air/current" }
        #expect(!requests.isEmpty && requests.allSatisfy { $0.query == "lat=27.95&lon=-82.46" })
    }

    /// Hazards where every source failed aren't cached, and a partial summary is
    /// fetched again after a minute, so a network blip doesn't stick for fifteen.
    @Test func failedHazardsAreNotCachedAsFresh() async throws {
        let env = try await Self.home()
        let air = #"{"location":{"latitude":27.95,"longitude":-82.46,"timezone":"America/New_York","utc_offset_seconds":-14400},"current":{"time":"2026-10-05T18:00:00Z","interval_seconds":3600,"us_aqi":61,"pm2_5":17.2,"pm10":30.1,"ozone":80.0,"dust":142.5},"source":{"name":"Open-Meteo, with Copernicus Atmosphere Monitoring Service data","fetched_at":"2026-10-05T18:05:00Z","stale":false}}"#
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProvider.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let start = ISODate.parse("2026-10-05T18:30:00Z")!
        func context(after seconds: TimeInterval) -> Context {
            Context(arguments: Arguments(command: "outlook"), environment: env,
                    terminal: TerminalInfo(isOutputTTY: false, isInputTTY: false, columns: 100, rows: 40, colorMode: .none,
                                           graphics: .none, program: nil, insideMultiplexer: false, reduceMotion: false),
                    http: http, now: start.addingTimeInterval(seconds))
        }
        func dustRequests() -> Int { StubProvider.seen.compactMap(\.url).filter { $0.path == "/v1/air/current" }.count }

        // Every source fails: a failure, and nothing cached.
        StubProvider.reset(Self.online)
        let ctx = context(after: 0)
        let place = try await ctx.resolveLocation()
        let failed = await ctx.hazards(place)
        #expect(failed.value == nil && failed.error != nil)
        #expect(ctx.cached(HazardSummary.self, key: "hazards-\(Context.placeKey(place))") == nil)

        // Only dust answers: a partial summary, kept for a minute.
        var routes = Self.online
        routes["api.dreadcast.app/v1/air/current"] = (200, air)
        StubProvider.reset(routes)
        let partial = try #require(await context(after: 10).hazards(place).value)
        #expect(partial.dust == 142.5 && partial.failures["tsunamis"] != nil)
        _ = await context(after: 40).hazards(place)
        #expect(dustRequests() == 1)
        _ = await context(after: 80).hazards(place)
        #expect(dustRequests() == 2)

        // Every source fails again: the partial summary shows, marked stale.
        StubProvider.reset(Self.online)
        let stale = await context(after: 200).hazards(place)
        #expect(stale.value?.dust == 142.5 && stale.isStale && stale.error != nil)
    }

    // MARK: Alerts and exit codes

    @Test func failOnSetsTheExitCode() async throws {
        let env = try await Self.home()
        #expect(try await Self.run(["alerts", "--plain", "--fail-on", "severe"], environment: env).code == .alertActive)
        #expect(try await Self.run(["alerts", "--plain", "--fail-on", "warning"], environment: env).code == .alertActive)
        #expect(try await Self.run(["alerts", "--plain", "--fail-on", "extreme"], environment: env).code == .ok)
        #expect(try await Self.run(["alerts", "--plain", "--fail-on", "sometimes"], environment: env).code == .usage)
    }

    @Test func unavailableAlertsExitThree() async throws {
        let env = try await Self.home()
        let result = try await Self.run(["alerts", "--json"], environment: env, routes: [Self.nws: (503, "busy")])
        #expect(result.code == .unavailable)
        #expect((try Self.json(result.out)["error"] as? String)?.contains("not an all-clear") == true)
    }

    @Test func alertsOutsideTheUSAreNotCovered() async throws {
        let env = try await Self.home(location: "51.51,-0.13")
        let result = try await Self.run(["alerts", "--json"], environment: env)
        #expect(result.code == .unavailable)
        #expect((try Self.json(result.out)["error"] as? String)?.contains("United States") == true)
        #expect(StubProvider.seen.allSatisfy { $0.url?.host != Self.nws })
    }

    // MARK: Saved places

    @Test func savedPlacesWorkAcrossCommands() async throws {
        let env = try await Self.home()
        #expect(try await Self.run(["places", "add", "28.54,-81.38", "--name", "mom", "--plain"], environment: env).code == .ok)
        #expect(try await Self.run(["places", "add", "28.54,-81.38", "--plain"], environment: env).code == .usage)
        let list = try Self.json(try await Self.run(["places", "--json"], environment: env).out)
        #expect((list["places"] as? [[String: Any]])?.map { $0["name"] as? String } == ["home", "mom"])

        let now = try await Self.run(["now", "-l", "mom", "--json"], environment: env)
        #expect((try Self.json(now.out)["location"] as? [String: Any])?["latitude"] as? Double == 28.54)

        let all = try Self.json(try await Self.run(["now", "--all", "--json"], environment: env).out)
        #expect(all["schema"] as? String == "dreadcast.now-all/1")
        #expect((all["places"] as? [Any])?.count == 2)
        // The shape the README's jq example relies on.
        let first = try #require((all["places"] as? [[String: Any]])?.first)
        #expect(first["name"] as? String == "home")
        #expect(((first["now"] as? [String: Any])?["conditions"] as? [String: Any])?["temperature"] as? Double == 71.2)

        let alerts = try await Self.run(["alerts", "--all", "--plain", "--fail-on", "severe"], environment: env)
        #expect(alerts.code == .alertActive)
        #expect(alerts.err.contains("at home"))

        #expect(try await Self.run(["places", "default", "mom", "--plain"], environment: env).code == .ok)
        #expect(try await Self.run(["places", "remove", "home", "--plain"], environment: env).code == .ok)
        #expect(try await Self.run(["places", "remove", "mom", "--plain"], environment: env).code == .usage)
    }

    @Test func everyPlaceWithOneOfflineIsIncomplete() async throws {
        let env = try await Self.home()
        try await Self.run(["places", "add", "28.54,-81.38", "--name", "mom", "--plain"], environment: env)
        let result = try await Self.run(["alerts", "--all", "--json"], environment: env, routes: [Self.nws: (500, "{}")])
        #expect(result.code == .unavailable)
        let places = try #require(try Self.json(result.out)["places"] as? [[String: Any]])
        #expect(places.allSatisfy { $0["alerts"] == nil && $0["error"] != nil })
    }

    // MARK: Setup and the app

    @Test func commandsNeedALocationFirst() async throws {
        let env = try await Self.home(location: nil)
        #expect(try await Self.run(["now", "--plain"], environment: env).code == .setupRequired)
        #expect(try await Self.run(["now", "--all", "--plain"], environment: env).code == .setupRequired)
    }

    @Test func topSaysWhatReplacedIt() async throws {
        let env = try await Self.home()
        for words in [["top"], ["top", "systems"], ["top", "radar"]] {
            let result = try await Self.run(words, environment: env)
            #expect(result.code == .usage)
            #expect(result.err.contains("dread systems"), "\(words)")
            #expect(StubProvider.seen.isEmpty)
        }
        let json = try Self.json(try await Self.run(["top", "--json"], environment: env).out)
        #expect((json["error"] as? String)?.contains("removed") == true)
    }

    // MARK: Systems

    /// Piped, `dread systems` lists every system once, most serious first, and names the
    /// sources it couldn't reach.
    @Test func systemsListOnceWhenPiped() async throws {
        let env = try await Self.home()
        let plain = try await Self.run(["systems"], environment: env)
        #expect(plain.code == .ok)
        let lines = plain.out.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("Weather systems near") == true)
        #expect(lines.dropFirst().first?.hasPrefix("Severe Thunderstorm Warning (ACTIVE, here") == true)
        #expect(lines.dropFirst(2).first?.hasPrefix("Flood Watch (ACTIVE, here") == true)
        #expect(plain.out.contains("Move to an interior room."))
        #expect(plain.out.contains("Radar (UNAVAILABLE)."))
        #expect(plain.out.contains("Sources: Open-Meteo, NWS."))
        #expect(plain.out.contains("Unavailable: radar,"))
        #expect(!plain.out.contains("▲"))

        let json = try Self.json(try await Self.run(["systems", "--json"], environment: env).out)
        #expect(json["schema"] as? String == "dreadcast.systems/1")
        let first = try #require((json["systems"] as? [[String: Any]])?.first)
        #expect(first["kind"] as? String == "alert")
        #expect(first["name"] as? String == "Severe Thunderstorm Warning")
        #expect(first["source"] as? String == "NWS")
        #expect(first["distance"] as? String == "here" && first["bearing"] == nil)
        let missing = (json["unavailable"] as? [[String: Any]])?.compactMap { $0["source"] as? String } ?? []
        #expect(missing.contains("radar") && !missing.contains("alerts"))

        let pretty = try await Self.run(["systems", "--pretty"], environment: env)
        let text = TextWidth.strippingANSI(pretty.out)
        #expect(text.contains("SYSTEMS") && text.contains("PID") && text.contains("▲ Severe Thunderstorm Warn…"))
        #expect(text.contains("Move to an interior room.") && text.contains("OPEN-METEO · NWS"))
    }

    @Test func systemsOfflineAreNeverAllClear() async throws {
        let env = try await Self.home()
        let result = try await Self.run(["systems"], environment: env, routes: [:])
        #expect(result.code == .unavailable)
        #expect(result.out.contains("NWS alerts (UNAVAILABLE)."))
        #expect(result.out.contains("Unavailable: conditions, alerts, radar"))
        #expect(!result.out.lowercased().contains("no active alerts"))
    }

    /// Offline, cached readings are listed but labeled stale, and nothing fresh exits 3.
    @Test func systemsFromTheCacheAloneAreStale() async throws {
        let env = try await Self.home()
        try await Self.run(["systems"], environment: env)
        let later = try await Self.run(["systems"], environment: env, routes: [:], at: "2026-10-05T18:45:00Z")
        #expect(later.code == .unavailable)
        #expect(later.out.contains("Severe Thunderstorm Warning (ACTIVE"))
        #expect(later.out.contains("Updated 15 min ago."))
        #expect(later.out.contains("Stale: conditions, alerts."))
    }

    /// Outside the US, the US-only sources are left out rather than called unavailable.
    @Test func systemsOutsideTheUSLeaveOutUSSources() async throws {
        let env = try await Self.home(location: "51.51,-0.13")
        let result = try await Self.run(["systems", "--json"], environment: env)
        #expect(result.code == .ok)
        let missing = (try Self.json(result.out)["unavailable"] as? [[String: Any]])?.compactMap { $0["source"] as? String } ?? []
        #expect(missing.contains("radar"))
        #expect(!missing.contains("alerts") && !missing.contains("severe-outlook") && !missing.contains("wildfires"))
        #expect(StubProvider.seen.allSatisfy { $0.url?.host != Self.nws })
    }

    @Test func helpCoversEveryCommand() async throws {
        let env = try await Self.home(location: nil)
        for topic in ["", "app", "systems", "places", "alerts", "radar", "scene", "prompt", "eta"] {
            let result = try await Self.run(topic.isEmpty ? ["help"] : ["help", topic], environment: env)
            #expect(result.code == .ok)
            #expect(result.out.contains("dread"), "help \(topic)")
        }
        let main = try await Self.run(["help"], environment: env).out
        #expect(!main.lowercased().contains("no server"))
    }

    @Test func themeSettingsSaveTheAppsNames() async throws {
        let env = try await Self.home()
        #expect(try await Self.run(["config", "set", "highlight", "violet", "--plain"], environment: env).code == .ok)
        #expect(try await Self.run(["config", "set", "map", "neutral", "--plain"], environment: env).code == .ok)
        #expect(try await Self.run(["config", "set", "forecast", "hourly", "--plain"], environment: env).code == .ok)
        let config = try Self.json(try await Self.run(["config", "--json"], environment: env).out)
        #expect(config["highlight"] as? String == "ai-violet")
        #expect(config["map"] as? String == "graphite")
        #expect(config["forecast"] as? String == "hourly")
        #expect(try await Self.run(["config", "set", "highlight", "chartreuse", "--plain"], environment: env).code == .usage)
        #expect(try await Self.run(["config", "set", "map", "daylight", "--plain"], environment: env).code == .usage)
        #expect(try await Self.run(["config", "set", "forecast", "never", "--plain"], environment: env).code == .usage)
    }

    @Test func scenesOnlyComeInSunsetAndNight() async throws {
        let env = try await Self.home()
        #expect(try await Self.run(["scene", "asteroid", "--time", "day", "--json"], environment: env).code == .usage)
        let night = try Self.json(try await Self.run(["scene", "asteroid", "--time", "night", "--json"], environment: env).out)
        #expect(night["period"] as? String == "night")
        let sunset = try Self.json(try await Self.run(["scene", "asteroid", "--time", "sunset", "--json"], environment: env).out)
        #expect(sunset["period"] as? String == "dusk")
    }

    @Test func versionMatchesTheRelease() async throws {
        let env = try await Self.home(location: nil)
        #expect(try await Self.run(["version"], environment: env).out == "dread \(Dreadcast.version)\n")
    }

    /// Every source's name stands apart from what it provides, however long the name.
    @Test func creditsKeepNamesApartFromTheirDetails() async throws {
        let env = try await Self.home(location: nil)
        let lines = try await Self.run(["credits", "--plain"], environment: env).out.split(separator: "\n").map(String.init)
        for name in ["Open-Meteo", "NOAA Enterprise Rain Rate", "National Weather Service", "American Meteor Society"] {
            let line = try #require(lines.first { $0.hasPrefix("  " + name) }, "\(name) is listed")
            #expect(line.dropFirst(2 + name.count).hasPrefix("  "), "\(name) has room before its details")
        }
        let copernicus = try #require(lines.firstIndex(of: "  Copernicus Atmosphere Monitoring Service"))
        #expect(lines[copernicus + 1].hasPrefix(String(repeating: " ", count: 29) + "Air quality and dust"))
    }
}

enum WeatherFixture {
    /// `/v1/weather/current` and `/v1/weather/forecast` for Tampa, in imperial units
    /// (dreadcast-server `docs/API.md`).
    static let current = """
    {"location":{"latitude":27.95,"longitude":-82.46,"elevation":6.0,"timezone":"America/New_York","timezone_abbreviation":"GMT-4","utc_offset_seconds":-14400},
     "current":{"time":"2026-10-06T04:00:00Z","interval_seconds":900,"temperature":71.2,"apparent_temperature":74.0,"relative_humidity":82,"weather_code":95,"is_day":true,"wind_speed":14,"wind_direction":225,"wind_gusts":31,"precipitation":0.1,"cloud_cover":100,"dew_point":66,"pressure":1004.2},
     "minutely_15":[{"time":"2026-10-06T04:00:00Z","precipitation":0.0,"weather_code":95},{"time":"2026-10-06T04:15:00Z","precipitation":0.05,"weather_code":95}],
     "units":{"temperature":"fahrenheit","wind_speed":"mph","precipitation":"inch"},
     "source":{"name":"Open-Meteo","url":"https://open-meteo.com/","license":"CC BY 4.0","provider":"open-meteo","fetched_at":"2026-10-05T18:25:00Z","expires_at":"2026-10-05T18:40:00Z","stale":false}}
    """

    static let forecast = """
    {"location":{"latitude":27.95,"longitude":-82.46,"elevation":6.0,"timezone":"America/New_York","timezone_abbreviation":"GMT-4","utc_offset_seconds":-14400},
     "hourly":[
       {"time":"2026-10-06T01:00:00Z","temperature":80,"apparent_temperature":85,"precipitation_probability":10,"precipitation":0,"weather_code":2,"is_day":true,"wind_speed":8,"cloud_cover":40,"wind_direction":200,"pressure":1007.5,"dew_point":66,"cape":2000},
       {"time":"2026-10-06T02:00:00Z","temperature":79,"apparent_temperature":84,"precipitation_probability":20,"precipitation":0,"weather_code":3,"is_day":true,"wind_speed":9,"cloud_cover":60,"wind_direction":210,"pressure":1006.8,"dew_point":66,"cape":2400},
       {"time":"2026-10-06T03:00:00Z","temperature":75,"apparent_temperature":78,"precipitation_probability":60,"precipitation":0.1,"weather_code":80,"is_day":true,"wind_speed":12,"cloud_cover":90,"wind_direction":220,"pressure":1005.6,"dew_point":67,"cape":2800},
       {"time":"2026-10-06T04:00:00Z","temperature":71,"apparent_temperature":74,"precipitation_probability":90,"precipitation":0.4,"weather_code":95,"is_day":true,"wind_speed":14,"cloud_cover":100,"wind_direction":225,"pressure":1004.2,"dew_point":66,"cape":3280},
       {"time":"2026-10-06T05:00:00Z","temperature":72,"apparent_temperature":75,"precipitation_probability":45,"precipitation":0.1,"weather_code":61,"is_day":true,"wind_speed":12,"cloud_cover":95,"wind_direction":230,"pressure":1004.8,"dew_point":66,"cape":2500}],
     "daily":[
       {"date":"2026-10-05","weather_code":95,"temperature_max":88,"temperature_min":69,"apparent_temperature_max":95,"apparent_temperature_min":72,"precipitation_probability_max":90,"precipitation_sum":1.2,"wind_speed_max":18,"wind_gusts_max":35,"uv_index_max":8,"sunrise":"2026-10-05T10:45:00Z","sunset":"2026-10-05T22:30:00Z"},
       {"date":"2026-10-06","weather_code":61,"temperature_max":87,"temperature_min":70,"apparent_temperature_max":94,"apparent_temperature_min":73,"precipitation_probability_max":40,"precipitation_sum":0.3,"wind_speed_max":12,"wind_gusts_max":20,"uv_index_max":6,"sunrise":"2026-10-06T10:45:00Z","sunset":"2026-10-06T22:30:00Z"}],
     "units":{"temperature":"fahrenheit","wind_speed":"mph","precipitation":"inch"},
     "source":{"name":"Open-Meteo","url":"https://open-meteo.com/","license":"CC BY 4.0","provider":"open-meteo","fetched_at":"2026-10-05T18:00:00Z","expires_at":"2026-10-05T19:00:00Z","stale":false}}
    """
}

enum AlertFixture {
    static let payload = """
    {"type":"FeatureCollection","features":[
      {"id":"a","properties":{"id":"urn:a","areaDesc":"Pinellas","status":"Actual","messageType":"Alert","severity":"Moderate",
        "certainty":"Likely","urgency":"Expected","event":"Flood Watch","senderName":"NWS Tampa Bay FL","headline":"Flood Watch",
        "description":"Heavy rain.","instruction":null,"expires":"2026-10-05T20:00:00-04:00","ends":"2026-10-06T08:00:00-04:00"}},
      {"id":"b","properties":{"id":"urn:b","areaDesc":"Hillsborough","status":"Actual","messageType":"Alert","severity":"Severe",
        "event":"Severe Thunderstorm Warning","senderName":"NWS Tampa Bay FL","headline":"Severe Thunderstorm Warning",
        "description":"A tornado is possible with this storm.","instruction":"Move to an interior room.",
        "expires":"2026-10-05T15:15:00-04:00"}},
      {"id":"c","properties":{"id":"urn:c","areaDesc":"Test","status":"Test","severity":"Minor","event":"Test Message","headline":"Test"}}
    ]}
    """
}
