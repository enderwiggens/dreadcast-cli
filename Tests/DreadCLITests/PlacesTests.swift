import Foundation
import Testing
@testable import DreadcastKit
import DreadTerminal
@testable import DreadCLI

@Suite("Places")
struct PlacesTests {
    static let naples = Place(name: "Naples, FL", coordinate: GeoCoordinate(latitude: 26.14, longitude: -81.79),
                              countryCode: "US", timeZone: "America/New_York", source: .zip)
    static let london = Place(name: "London, England", coordinate: GeoCoordinate(latitude: 51.51, longitude: -0.13),
                              countryCode: "GB", timeZone: "Europe/London", source: .search)
    static let saved = [SavedPlace(name: "home", place: naples), SavedPlace(name: "mom", place: SceneTests.tampa),
                        SavedPlace(name: "london", place: london)]

    static func context(places: [SavedPlace], arguments: Arguments = Arguments(command: "now")) throws -> Context {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dreadcast-places-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var config = Config()
        config.places = places
        let environment = ["DREADCAST_CONFIG_DIR": directory.path, "DREADCAST_CACHE_DIR": directory.appendingPathComponent("cache").path]
        try ConfigStore.save(config, to: Paths.resolve(environment: environment))
        let terminal = TerminalInfo(isOutputTTY: true, isInputTTY: true, columns: 120, rows: 44, colorMode: .truecolor,
                                    graphics: .none, program: nil, insideMultiplexer: false, reduceMotion: false)
        return Context(arguments: arguments, environment: environment, terminal: terminal, http: OfflineProtocol.http,
                       now: ISODate.parse("2026-10-06T23:30:00Z")!)
    }

    // MARK: Config

    @Test func olderConfigsBecomeAHomePlace() throws {
        let legacy = #"{"version":1,"location":{"name":"Naples, FL","coordinate":{"latitude":26.14,"longitude":-81.79},"countryCode":"US","source":"zip"},"units":"imperial"}"#
        let config = try JSONDecoder.dreadcast.decode(Config.self, from: Data(legacy.utf8))
        #expect(config.places.map(\.name) == ["home"])
        #expect(config.location?.name == "Naples, FL")
    }

    @Test func placesSurviveARoundTripAndKeepLocationForOlderBuilds() throws {
        var config = Config()
        config.places = Self.saved
        let data = try JSONEncoder.dreadcast.encode(config)
        let decoded = try JSONDecoder.dreadcast.decode(Config.self, from: data)
        #expect(decoded.places == Self.saved)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["location"] as? [String: Any])?["name"] as? String == "Naples, FL")
    }

    @Test func settingTheLocationMovesOrReplacesTheDefault() {
        var config = Config()
        config.location = Self.naples
        #expect(config.places.map(\.name) == ["home"])
        config.places = Self.saved
        // A saved place moves first, keeping every name.
        config.location = SceneTests.tampa
        #expect(config.places.map(\.name) == ["mom", "home", "london"])
        // A new place replaces the default, keeping its name.
        let miami = Place(name: "Miami, FL", coordinate: GeoCoordinate(latitude: 25.76, longitude: -80.19), countryCode: "US", source: .zip)
        config.location = miami
        #expect(config.places.map(\.name) == ["mom", "home", "london"])
        #expect(config.location?.name == "Miami, FL")
    }

    // MARK: Names and rules

    @Test func namesAreShortAndPlain() {
        #expect(PlaceBook.isValidName("mom"))
        #expect(PlaceBook.isValidName("lake-house-2"))
        #expect(!PlaceBook.isValidName(""))
        #expect(!PlaceBook.isValidName("33602"))
        #expect(!PlaceBook.isValidName("Mom"))
        #expect(!PlaceBook.isValidName("mom's"))
        #expect(!PlaceBook.isValidName(String(repeating: "a", count: 21)))
        #expect(PlaceBook.suggestedName(for: SceneTests.tampa, avoiding: []) == "tampa")
        #expect(PlaceBook.suggestedName(for: SceneTests.tampa, avoiding: [SavedPlace(name: "tampa", place: Self.naples)]) == "tampa-2")
        let saoPaulo = Place(name: "São Paulo, Brazil", coordinate: GeoCoordinate(latitude: -23.55, longitude: -46.63), source: .search)
        #expect(PlaceBook.suggestedName(for: saoPaulo, avoiding: []) == "sao-paulo")
        let zip = Place(name: "33602", coordinate: GeoCoordinate(latitude: 27.95, longitude: -82.46), source: .zip)
        #expect(PlaceBook.suggestedName(for: zip, avoiding: []) == "place")
    }

    @Test func addingRemovingAndReordering() throws {
        var places = try PlaceBook.add(Self.naples, name: "home", to: [])
        places = try PlaceBook.add(SceneTests.tampa, name: nil, to: places)
        #expect(places.map(\.name) == ["home", "tampa"])
        #expect(throws: PlaceBook.Problem.alreadySaved("tampa")) { try PlaceBook.add(SceneTests.tampa, name: "mom", to: places) }
        #expect(throws: PlaceBook.Problem.taken("home")) { try PlaceBook.add(Self.london, name: "home", to: places) }
        #expect(throws: PlaceBook.Problem.invalidName("Mom!")) { try PlaceBook.add(Self.london, name: "Mom!", to: places) }
        places = try PlaceBook.rename("tampa", to: "mom", in: places)
        #expect(places.map(\.name) == ["home", "mom"])
        places = try PlaceBook.makeDefault("MOM", in: places)
        #expect(places.map(\.name) == ["mom", "home"])
        places = try PlaceBook.remove("mom", from: places)
        #expect(places.map(\.name) == ["home"])
        #expect(throws: PlaceBook.Problem.onlyPlace) { try PlaceBook.remove("home", from: places) }
        #expect(throws: PlaceBook.Problem.notFound("nowhere")) { try PlaceBook.makeDefault("nowhere", in: places) }
    }

    @Test func placesStopAtTheLimit() throws {
        var places: [SavedPlace] = []
        for i in 0..<PlaceBook.limit {
            let place = Place(name: "Spot \(i)", coordinate: GeoCoordinate(latitude: 30 + Double(i), longitude: -90), countryCode: "US", source: .search)
            places = try PlaceBook.add(place, name: nil, to: places)
        }
        #expect(throws: PlaceBook.Problem.full) { try PlaceBook.add(Self.london, name: nil, to: places) }
    }

    @Test func savedNamesResolveWithoutASearch() async throws {
        let ctx = try Self.context(places: Self.saved, arguments: Arguments.parse(["now", "--location", "Mom"]))
        #expect(try await ctx.resolveLocation() == SceneTests.tampa)
        let plain = try Self.context(places: Self.saved)
        #expect(try await plain.resolveLocation() == Self.naples)
    }

    @Test func everyPlaceNeedsSavedPlaces() async throws {
        let ctx = try Self.context(places: [], arguments: Arguments.parse(["now", "--all", "--plain"]))
        #expect(await NowCommand.all(ctx) == .setupRequired)
        #expect(try Self.context(places: Self.saved, arguments: Arguments.parse(["--all"])).opensApp == false)
    }

    // MARK: Rows

    static func reading(_ saved: SavedPlace, alerts: [WeatherAlert]?, loaded: Bool = true) -> PlaceRows.Reading {
        PlaceRows.Reading(saved: saved, weather: SceneTests.fetched(VoiceTests.report(code: 1)),
                          alerts: loaded ? SceneTests.fetched(alerts) : nil, nowcast: nil)
    }

    @Test func rowsNeverCallMissingAlertsClear() throws {
        let ctx = try Self.context(places: Self.saved)
        func row(_ r: PlaceRows.Reading) -> String {
            TextWidth.strippingANSI(PlaceRows.line(r, ctx: ctx, width: 120, highlighted: false, viewing: false))
        }
        #expect(row(Self.reading(Self.saved[0], alerts: [])).contains("none"))
        #expect(row(Self.reading(Self.saved[0], alerts: nil)).contains("unknown"))
        #expect(row(Self.reading(Self.saved[0], alerts: nil, loaded: false)).contains("…"))
        #expect(row(Self.reading(Self.saved[2], alerts: nil)).contains("NWS covers the US"))
        let warned = row(Self.reading(Self.saved[1], alerts: [SceneTests.warning(), SceneTests.warning()]))
        #expect(warned.contains("Tornado Warning +1"))
        #expect(PlaceRows.plain(Self.reading(Self.saved[1], alerts: [SceneTests.warning()]), ctx: ctx).contains("mom (Tampa, FL): 75°F"))
        #expect(PlaceRows.plain(Self.reading(Self.saved[0], alerts: nil), ctx: ctx).contains("Alerts unavailable."))
    }

    @Test func alertsJSONExplainsUncoveredPlaces() throws {
        let json = AlertsAllJSON([(Self.saved[0], SceneTests.fetched([SceneTests.warning()])), (Self.saved[2], nil)], now: Date())
        #expect(json.places[0].alerts?.count == 1 && json.places[0].error == nil)
        #expect(json.places[1].alerts == nil && json.places[1].error?.contains("United States") == true)
    }

    // MARK: The app

    @Test func otherPlacesAreWatchedLightly() {
        #expect(DreadApp.sources(for: 0, selected: 0, tab: .radar, highlighted: 1) == nil)
        #expect(DreadApp.sources(for: 1, selected: 0, tab: .radar, highlighted: 1) == ["weather", "alerts"])
        #expect(DreadApp.sources(for: 1, selected: 0, tab: .places, highlighted: 1) == ["weather", "alerts", "nowcast"])
        #expect(DreadApp.sources(for: 2, selected: 0, tab: .places, highlighted: 1) == ["weather", "alerts"])
    }

    @Test func thePlacesTabAppearsWithASecondPlace() {
        #expect(!AppTab.visible(places: 1).contains(.places))
        #expect(AppTab.visible(places: 3).last == .places)
        #expect(AppTab.named("places") == .places)
        #expect(AppTab.named("8") == .places)
    }

    static func frame(_ ctx: Context, alertsAt index: Int?, selected: Int = 0, height: Int = 30) -> AppFrame {
        let watched = saved.enumerated().map { i, s in
            var snapshot = LiveData.Snapshot()
            snapshot.weather = SceneTests.fetched(VoiceTests.report(code: 1))
            snapshot.alerts = s.place.isUnitedStates ? SceneTests.fetched(i == index ? [SceneTests.warning()] : []) : .failure("not covered")
            return Watched(saved: s, snapshot: snapshot)
        }
        return AppFrame(ctx: ctx, place: saved[selected].place, snapshot: watched[selected].snapshot, width: 120, height: height,
                        elapsed: 0, places: watched, selected: selected)
    }

    @Test func theHeaderNamesAlertsAtOtherPlaces() throws {
        let ctx = try Self.context(places: Self.saved)
        let elsewhere = DreadApp.header(tab: .radar, frame: Self.frame(ctx, alertsAt: 1), styler: ctx.styler).map(TextWidth.strippingANSI)
        #expect(elsewhere[0].contains("TORNADO WARNING · mom"))
        #expect(elsewhere[0].contains("home · 1 of 3"))
        #expect(elsewhere[1].contains("8 Places 1") && !elsewhere[1].contains("Alerts 1"))
        let here = DreadApp.header(tab: .radar, frame: Self.frame(ctx, alertsAt: 0), styler: ctx.styler).map(TextWidth.strippingANSI)
        #expect(here[0].contains("TORNADO WARNING") && !here[0].contains("· mom"))
        #expect(here[1].contains("Alerts 1"))
        let footer = DreadApp.footer(view: RadarView(ctx: ctx), frame: Self.frame(ctx, alertsAt: 1), styler: ctx.styler).map(TextWidth.strippingANSI)
        #expect(footer[1].contains("1–8 views") && footer[1].contains("[ ] place") && footer[1].contains("a go to alert"))
    }

    @Test func thePlacesTabListsAndChooses() throws {
        let ctx = try Self.context(places: Self.saved)
        let view = PlacesView()
        for height in [6, 12, 30] {
            guard case .lines(let lines) = view.body(Self.frame(ctx, alertsAt: 1, height: height)) else { Issue.record("expected text"); return }
            #expect(lines.count <= height)
        }
        let f = Self.frame(ctx, alertsAt: 1)
        guard case .lines(let lines) = view.body(f) else { return }
        let text = lines.map(TextWidth.strippingANSI)
        #expect(text.contains { $0.contains("home") && $0.contains("Naples, FL") })
        #expect(text.contains { $0.contains("london") && $0.contains("NWS covers the US") })
        #expect(view.takeChoice() == nil)
        #expect(view.handle(.down, frame: f))
        #expect(view.handle(.enter, frame: f))
        #expect(view.takeChoice() == 1)
        #expect(view.takeChoice() == nil)
        _ = view.handle(.down, frame: f); _ = view.handle(.down, frame: f); _ = view.handle(.down, frame: f)
        #expect(view.highlighted == 2)
    }

    @Test func switchingPlacesResetsViews() throws {
        let systems = SystemsView()
        systems.selected = 4
        systems.placeChanged()
        #expect(systems.selected == 0)
        let alerts = AlertsView()
        alerts.offset = 9
        alerts.placeChanged()
        #expect(alerts.offset == 0)
    }
}
