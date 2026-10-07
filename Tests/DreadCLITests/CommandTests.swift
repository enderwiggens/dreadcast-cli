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

    override func startLoading() {
        let url = request.url!
        let route = Self.lock.withLock { () -> (status: Int, body: String)? in
            Self.requests.append(request)
            return Self.routes[url.host ?? ""]
        }
        guard let route else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: route.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(route.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Commands run as a person or script would run them: real argument parsing, config and
/// cache on disk, and dispatch, with providers stubbed. The suite is serialized because
/// the stub's routes are shared.
@Suite("Commands", .serialized)
struct CommandTests {
    static let forecast = "api.open-meteo.com"
    static let nws = "api.weather.gov"
    static let online: [String: (Int, String)] = [forecast: (200, WeatherFixture.payload), nws: (200, AlertFixture.payload)]

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
                    tty: Bool = false) async throws -> (code: ExitCode, out: String, err: String) {
        StubProvider.reset(routes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProvider.self]
        let terminal = TerminalInfo(isOutputTTY: tty, isInputTTY: tty, columns: 100, rows: 40, colorMode: .none,
                                    graphics: .none, program: nil, insideMultiplexer: false, reduceMotion: false)
        let ctx = Context(arguments: try Arguments.parse(words), environment: environment, terminal: terminal,
                          http: HTTPClient(session: URLSession(configuration: configuration)),
                          now: ISODate.parse("2026-10-05T18:30:00Z")!)
        let buffer = Context.OutputBuffer()
        ctx.output = buffer
        let code = await Dread.dispatch(ctx)
        return (code, buffer.text, buffer.errors)
    }

    static func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: The quick look

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
        let partial = try await Self.run(["now", "--plain"], environment: try await Self.home(), routes: [Self.forecast: (200, WeatherFixture.payload), Self.nws: (500, "{}")])
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
        #expect(StubProvider.seen.allSatisfy { $0.url?.host != Self.forecast && $0.url?.host != Self.nws })
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

    @Test func theAppNeedsAnInteractiveTerminal() async throws {
        let env = try await Self.home()
        let result = try await Self.run(["top", "radar"], environment: env)
        #expect(result.code == .usage)
        #expect(result.err.contains("interactive terminal"))
        #expect(try await Self.run(["top", "tornado"], environment: env).code == .usage)
    }

    @Test func helpCoversEveryCommand() async throws {
        let env = try await Self.home(location: nil)
        for topic in ["", "top", "places", "alerts", "radar", "scene", "prompt", "eta"] {
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
}

enum WeatherFixture {
    static let payload = """
    {"latitude":27.95,"longitude":-82.46,"utc_offset_seconds":-14400,"timezone":"America/New_York",
     "current":{"time":1791259200,"interval":900,"temperature_2m":71.2,"apparent_temperature":74.0,"relative_humidity_2m":82,
       "dew_point_2m":66,"weather_code":95,"wind_speed_10m":14,"wind_direction_10m":225,"wind_gusts_10m":31,"is_day":1,
       "precipitation":0.1,"pressure_msl":1004.2,"cloud_cover":100},
     "minutely_15":{"time":[1791259200,1791260100],"precipitation":[0.0,0.05],"weather_code":[95,95]},
     "hourly":{"time":[1791248400,1791252000,1791255600,1791259200,1791262800],
       "temperature_2m":[80,79,75,71,72],"apparent_temperature":[85,84,78,74,75],"precipitation_probability":[10,20,60,90,45],
       "precipitation":[0,0,0.1,0.4,0.1],"weather_code":[2,3,80,95,61],"is_day":[1,1,1,1,1],"wind_speed_10m":[8,9,12,14,12],
       "wind_direction_10m":[200,210,220,225,230],"cloud_cover":[40,60,90,100,95],"pressure_msl":[1007.5,1006.8,1005.6,1004.2,1004.8],
       "dew_point_2m":[66,66,67,66,66],"cape":[2000,2400,2800,3280,2500]},
     "daily":{"time":[1791172800,1791259200],"weather_code":[95,61],"temperature_2m_max":[88,87],"temperature_2m_min":[69,70],
       "apparent_temperature_max":[95,94],"apparent_temperature_min":[72,73],"precipitation_probability_max":[90,40],
       "precipitation_sum":[1.2,0.3],"wind_speed_10m_max":[18,12],"wind_gusts_10m_max":[35,20],"uv_index_max":[8,6],
       "sunrise":[1791197100,1791283500],"sunset":[1791239400,1791325800]}}
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
