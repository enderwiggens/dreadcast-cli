import Foundation
import Testing
@testable import DreadCLI
@testable import DreadcastKit
import DreadTerminal

@Suite("Scenes")
struct SceneTests {
    static let moon = LunarPhase(at: Date(timeIntervalSince1970: 1_791_259_200))

    @Test func namesAliasesAndProScenes() {
        #expect(SceneID.lookup("asteroid") == .scene(.asteroid))
        #expect(SceneID.lookup("Deep Trouble") == .scene(.deepTrouble))
        #expect(SceneID.lookup("beach") == .scene(.clearForNow))
        #expect(SceneID.lookup("ufo") == .scene(.uap))
        #expect(SceneID.lookup("volcano") == .pro("Volcano Watch"))
        #expect(SceneID.lookup("black-hole") == .pro("Black Hole"))
        #expect(SceneID.lookup("nope") == .unknown)
        #expect(SceneID.allCases.count == 8)
    }

    @Test func followsTheAppsSchedule() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        func period(_ hour: Int) -> ScenePeriod {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: hour, minute: 30))!
            return ScenePeriod.at(date, timeZone: zone)
        }
        #expect(period(4) == .night)
        #expect(period(5) == .dawn)
        #expect(period(8) == .day)
        #expect(period(16) == .day)
        #expect(period(17) == .dusk)
        #expect(period(20) == .night)
        #expect(ScenePeriod.night.next == .dawn)
    }

    @Test func dailySceneHoldsAllDayAndChangesTomorrow() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let morning = ISODate.parse("2026-10-06T12:00:00Z")!
        let evening = ISODate.parse("2026-10-07T02:00:00Z")!   // 10 PM the same local day
        let tomorrow = ISODate.parse("2026-10-07T12:00:00Z")!
        #expect(SceneID.daily(on: morning, timeZone: zone) == SceneID.daily(on: evening, timeZone: zone))
        #expect(SceneID.daily(on: morning, timeZone: zone) != SceneID.daily(on: tomorrow, timeZone: zone))
    }

    @Test func everySceneDrawsAtEverySize() {
        let sizes = [(20, 8), (20, 10), (40, 14), (84, 20), (96, 32), (133, 82), (220, 120), (400, 180)]
        for scene in SceneID.allCases {
            for period in ScenePeriod.allCases {
                for (width, height) in sizes {
                    for layout in SceneLayout.allCases {
                        for time in [0.0, 13.7] {
                            let raster = ScenePainter(scene: scene, period: period, time: time, still: time == 0, moon: Self.moon,
                                                      layout: layout)
                                .paint(width: width, height: height)
                            #expect(raster.width == width && raster.height == height)
                        }
                    }
                }
            }
        }
    }

    @Test func paintingIsDeterministicAndAnimates() {
        let painter = ScenePainter(scene: .solarTantrum, period: .night, time: 2, still: false, moon: Self.moon)
        #expect(painter.paint(width: 96, height: 32).pixels == painter.paint(width: 96, height: 32).pixels)
        let later = ScenePainter(scene: .solarTantrum, period: .night, time: 3, still: false, moon: Self.moon)
        #expect(painter.paint(width: 96, height: 32).pixels != later.paint(width: 96, height: 32).pixels)
    }

    @Test func linesComeFromApprovedCopy() {
        #expect(SceneID.superstorm.line(for: .dusk) == "A good day to have an inside.")
        #expect(SceneID.solarTantrum.line(for: .day) == "The sun is expressing itself.")
        for scene in SceneID.allCases {
            for period in ScenePeriod.allCases { #expect(!scene.line(for: period).isEmpty) }
        }
    }

    @Test func pixelTypeIsFourEvenRows() {
        #expect(PixelFont.width("74°F") == 5 + 1 + 5 + 1 + 3 + 1 + 4)
        let lines = PixelFont.lines("74°F", styler: Styler(mode: .none), color: Theme.porcelain, accent: Theme.lamp)
        #expect(lines.count == 4)
        #expect(Set(lines.map { TextWidth.of($0) }) == [PixelFont.width("74°F")])
        #expect(lines.joined().contains("█"))
    }

    // MARK: Banner and readings

    static func context(rows: Int = 44, scene: String = "asteroid", banner: Bool = true, quips: Bool = true,
                        arguments: Arguments = Arguments(command: "now")) throws -> Context {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dreadcast-scene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Config()
        config.scene = scene
        config.sceneBanner = banner
        config.quips = quips
        let environment = ["DREADCAST_CONFIG_DIR": directory.path, "DREADCAST_CACHE_DIR": directory.appendingPathComponent("cache").path]
        try ConfigStore.save(config, to: Paths.resolve(environment: environment))
        let terminal = TerminalInfo(isOutputTTY: true, isInputTTY: true, columns: 100, rows: rows, colorMode: .truecolor,
                                    graphics: .none, program: nil, insideMultiplexer: false, reduceMotion: false)
        return Context(arguments: arguments, environment: environment, terminal: terminal,
                       now: ISODate.parse("2026-10-06T23:30:00Z")!)
    }

    static let tampa = Place(name: "Tampa, FL", coordinate: GeoCoordinate(latitude: 27.95, longitude: -82.46),
                             countryCode: "US", timeZone: "America/New_York", source: .zip)

    static func warning() -> WeatherAlert {
        WeatherAlert(id: "1", event: "Tornado Warning", headline: "Tornado Warning", areaDescription: "Hillsborough",
                     description: "", instruction: "Take shelter now.", severity: .extreme)
    }

    static func fetched<T>(_ value: T?) -> Fetched<T> {
        value.map { Fetched(value: $0, storedAt: Date(), error: nil, isStale: false) } ?? .failure("offline")
    }

    @Test func bannerShowsOnlyWhenAlertsAreKnownAndClear() throws {
        let ctx = try Self.context()
        let report = VoiceTests.report(code: 1)
        let clear = NowCommand.banner(place: Self.tampa, alerts: Self.fetched([]), report: report, ctx: ctx, width: 86)
        #expect(clear.count == 10)
        #expect(NowCommand.banner(place: Self.tampa, alerts: Self.fetched([Self.warning()]), report: report, ctx: ctx, width: 86).isEmpty)
        #expect(NowCommand.banner(place: Self.tampa, alerts: Self.fetched(nil), report: report, ctx: ctx, width: 86).isEmpty)
        let short = try Self.context(rows: 30)
        #expect(NowCommand.banner(place: Self.tampa, alerts: Self.fetched([]), report: report, ctx: short, width: 86).isEmpty)
        let off = try Self.context(banner: false)
        #expect(NowCommand.banner(place: Self.tampa, alerts: Self.fetched([]), report: report, ctx: off, width: 86).isEmpty)
    }

    @Test func topShowsAStripOnlyWhenTallAndClear() throws {
        let ctx = try Self.context(rows: 44)
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        var clear = TopCommand.Snapshot()
        clear.alerts = Self.fetched([])
        var strip = TopCommand.Strip(started: Date())
        let lines = TopCommand.stripLines(ctx: ctx, place: Self.tampa, snapshot: clear, zone: zone, width: 100, height: 44, strip: strip)
        #expect(lines.count == TopCommand.Strip.rows + 1)
        #expect(TopCommand.stripLines(ctx: ctx, place: Self.tampa, snapshot: clear, zone: zone, width: 100, height: 30, strip: strip).isEmpty)
        var warned = TopCommand.Snapshot()
        warned.alerts = Self.fetched([Self.warning()])
        #expect(TopCommand.stripLines(ctx: ctx, place: Self.tampa, snapshot: warned, zone: zone, width: 100, height: 44, strip: strip).isEmpty)
        #expect(TopCommand.stripLines(ctx: ctx, place: Self.tampa, snapshot: TopCommand.Snapshot(), zone: zone, width: 100, height: 44, strip: strip).isEmpty)
        strip.hidden = true
        #expect(TopCommand.stripLines(ctx: ctx, place: Self.tampa, snapshot: clear, zone: zone, width: 100, height: 44, strip: strip).isEmpty)
    }

    @Test func readingsReplaceTheLineDuringAlerts() throws {
        let ctx = try Self.context()
        let report = VoiceTests.report(code: 1)
        func text(_ alerts: Fetched<[WeatherAlert]>?) -> String {
            let readings = SceneCommand.Readings(place: Self.tampa, weather: Self.fetched(report), alerts: alerts)
            return TextWidth.strippingANSI(SceneInfo.lines(scene: .asteroid, period: .dusk, readings: readings, ctx: ctx, width: 100).joined(separator: "\n"))
        }
        let line = SceneID.asteroid.line(for: .dusk)
        let calm = text(Self.fetched([]))
        #expect(calm.contains(line))
        #expect(calm.contains("No active alerts"))
        #expect(calm.contains("OPEN-METEO · NWS"))
        let warned = text(Self.fetched([Self.warning()]))
        #expect(!warned.contains(line))
        #expect(warned.contains("TORNADO WARNING"))
        let unknown = text(Self.fetched(nil))
        #expect(!unknown.contains(line))
        #expect(unknown.contains("This is not an all-clear."))
    }

    @Test func upcomingDaysStartToday() throws {
        var report = VoiceTests.report(code: 1)
        let zone = report.timeZone
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let now = ISODate.parse("2026-10-06T16:00:00Z")!
        let today = calendar.startOfDay(for: now)
        report.daily = (-1..<7).map { offset in
            WeatherReport.Day(date: calendar.date(byAdding: .day, value: offset, to: today)!, high: 80, low: 70, apparentHigh: nil,
                              apparentLow: nil, weatherCode: 2, precipitationProbability: 20, precipitation: 0, windSpeed: nil,
                              windGusts: nil, uvIndex: nil, sunrise: nil, sunset: nil)
        }
        let days = DayRows.upcoming(report, from: now, count: 5)
        #expect(days.count == 5)
        #expect(days.first?.date == today)
    }

    @Test func weatherIsAnotherNameForTheBaseCommand() throws {
        #expect(try Arguments.parse(["weather"]).command == "weather")
        let scene = try Arguments.parse(["scene", "uap", "--time", "night", "--still"])
        #expect(scene.command == "scene")
        #expect(scene.positionals == ["uap"])
        #expect(scene.value("time") == "night")
    }

    @Test func sceneDefaultsToAsteroidWatchWithTheBannerOn() throws {
        let config = try JSONDecoder.dreadcast.decode(Config.self, from: Data(#"{"units":"metric"}"#.utf8))
        #expect(config.scene == "asteroid")
        #expect(config.sceneBanner)
        let early = try JSONDecoder.dreadcast.decode(Config.self, from: Data(#"{"scene":"off"}"#.utf8))
        #expect(early.scene == "asteroid" && !early.sceneBanner)
        let ctx = try Self.context()
        #expect(SceneCommand.configuredScene(ctx, timeZone: .current) == .asteroid)
    }

    @Test func configSetsTheSceneAndTheBanner() throws {
        func run(_ words: [String]) throws -> (ExitCode, Config) {
            let ctx = try Self.context(arguments: try Arguments.parse(["config", "set"] + words))
            let code = try ConfigCommand.run(ctx)
            return (code, ConfigStore.load(from: ctx.paths))
        }
        let picked = try run(["scene", "UAP"])
        #expect(picked.0 == .ok && picked.1.scene == "uap")
        let daily = try run(["scene", "daily"])
        #expect(daily.1.scene == "daily")
        let hidden = try run(["scene-banner", "off"])
        #expect(hidden.0 == .ok && !hidden.1.sceneBanner)
        let alias = try run(["scene", "off"])
        #expect(alias.0 == .ok && !alias.1.sceneBanner && alias.1.scene == "asteroid")
        #expect(try run(["scene", "volcano"]).0 == .usage)
        #expect(try run(["scene-banner", "maybe"]).0 == .usage)
    }
}
