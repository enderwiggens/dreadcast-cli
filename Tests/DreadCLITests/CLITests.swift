import Foundation
import Testing
@testable import DreadCLI
@testable import DreadcastKit
import DreadTerminal

@Suite("Arguments")
struct ArgumentTests {
    @Test func defaultsToNow() throws {
        let arguments = try Arguments.parse([])
        #expect(arguments.command == "now")
    }

    @Test func parsesCommandsOptionsAndFlags() throws {
        let arguments = try Arguments.parse(["radar", "--range", "75", "--palette=viridis", "--still", "-j"])
        #expect(arguments.command == "radar")
        #expect(arguments.integer("range") == 75)
        #expect(arguments.value("palette") == "viridis")
        #expect(arguments.has("still"))
        #expect(arguments.has("json"))
    }

    @Test func keepsCoordinatesAsPositionals() throws {
        let arguments = try Arguments.parse(["setup", "27.95,-82.46"])
        #expect(arguments.command == "setup")
        #expect(arguments.positionals == ["27.95,-82.46"])
        let spaced = try Arguments.parse(["setup", "27.95", "-82.46"])
        #expect(spaced.positionals == ["27.95", "-82.46"])
    }

    @Test func rejectsUnknownOptions() {
        #expect(throws: Arguments.ParseError.unknownOption("--nope")) { _ = try Arguments.parse(["--nope"]) }
        #expect(throws: Arguments.ParseError.missingValue("--range")) { _ = try Arguments.parse(["radar", "--range"]) }
    }

    @Test func versionFlag() throws {
        #expect(try Arguments.parse(["--version"]).command == "version")
    }
}

@Suite("Voice")
struct VoiceTests {
    static func report(code: Int, isDay: Bool = true, temperature: Double = 75) -> WeatherReport {
        WeatherReport(fetchedAt: Date(), coordinate: GeoCoordinate(latitude: 0, longitude: 0), units: .imperial,
                      timeZoneIdentifier: "America/New_York",
                      current: .init(time: Date(), temperature: temperature, apparentTemperature: temperature, humidity: 50,
                                     dewPoint: 60, weatherCode: code, windSpeed: 5, windDirection: 90, windGusts: nil,
                                     isDay: isDay, precipitation: 0, pressure: 1012, cloudCover: 10),
                      minutely: [], hourly: [], daily: [])
    }

    @Test func neverJokesDuringAlerts() {
        #expect(Quip.line(report: Self.report(code: 95), alertsActive: true, now: Date()) == nil)
    }

    @Test func matchesConditions() {
        // 2026-10-07 is a Wednesday; 3 PM Eastern avoids the morning line.
        let afternoon = ISODate.parse("2026-10-07T19:00:00Z")!
        #expect(Quip.line(report: Self.report(code: 95), alertsActive: false, now: afternoon) == "A good day to have an inside.")
        #expect(Quip.line(report: Self.report(code: 61), alertsActive: false, now: afternoon) == "At least you’ll know what to wear.")
        let morning = ISODate.parse("2026-10-07T12:30:00Z")! // 8:30 AM Eastern
        #expect(Quip.line(report: Self.report(code: 1), alertsActive: false, now: morning) == "Your 9 AM remains scheduled.")
    }

    @Test func outlookCommentaryTracksKp() {
        #expect(Quip.outlook(kp: 5) == "The sun is expressing itself.")
        #expect(Quip.outlook(kp: 2) == "The sun has nothing further to add.")
    }
}

@Suite("Formatting and thresholds")
struct FormattingTests {
    let fmt = Formatter(units: .imperial, timeZone: TimeZone(identifier: "America/New_York")!)

    @Test func wind() {
        #expect(fmt.wind(speed: 14, gust: 31, direction: 225) == "SW 14 G 31 mph")
        #expect(fmt.wind(speed: 14, gust: 16, direction: 225) == "SW 14 mph")
        #expect(fmt.wind(speed: 0.2, gust: nil, direction: nil) == "Calm")
    }

    @Test func temperaturesAndDistances() {
        #expect(fmt.temperature(71.4, unit: true) == "71°F")
        #expect(fmt.distance(miles: 1005) == "1,005 mi")
        #expect(Formatter(units: .metric, timeZone: .current).distance(miles: 10) == "16 km")
    }

    @Test func relativeTimes() {
        let now = Date()
        #expect(Formatter.ago(now.addingTimeInterval(-20), now: now) == "just now")
        #expect(Formatter.ago(now.addingTimeInterval(-125), now: now) == "3 min ago")
        #expect(Formatter.duration(minutes: 70) == "1 h 10 min")
    }

    @Test func failOnThresholds() {
        let warning = WeatherAlert(id: "1", event: "Severe Thunderstorm Warning", headline: "", areaDescription: "",
                                   description: "", instruction: nil, severity: .severe)
        let advisory = WeatherAlert(id: "2", event: "Wind Advisory", headline: "", areaDescription: "",
                                    description: "", instruction: nil, severity: .minor)
        #expect(AlertsCommand.Threshold("severe")!.matches(warning))
        #expect(!AlertsCommand.Threshold("severe")!.matches(advisory))
        #expect(AlertsCommand.Threshold("advisory")!.matches(advisory))
        #expect(AlertsCommand.Threshold("watch")!.matches(warning))
        #expect(AlertsCommand.Threshold("bogus") == nil)
    }

    @Test func promptShortNames() {
        #expect(PromptCommand.shortName("Severe Thunderstorm Warning") == "Svr T-Storm Warning")
    }
}

@Suite("Cache")
struct CacheTests {
    @Test func roundTripsAndLocks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dreadcast-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = DiskCache(directory: directory)
        let stored = Date(timeIntervalSince1970: 1_791_259_200)
        cache.write(["a", "b"], key: "list/key", at: stored)
        let read = try #require(cache.read([String].self, key: "list/key"))
        #expect(read.value == ["a", "b"])
        #expect(read.storedAt == stored)
        let inner = cache.withExclusiveLock("test") { cache.withExclusiveLock("test") { 1 } }
        #expect(inner == .some(nil))
    }

    @Test func configToleratesMissingKeys() throws {
        let config = try JSONDecoder.dreadcast.decode(Config.self, from: Data(#"{"units":"metric"}"#.utf8))
        #expect(config.units == .metric)
        #expect(config.palette == .dreadcast)
        #expect(config.radarRange == 35)
    }
}
