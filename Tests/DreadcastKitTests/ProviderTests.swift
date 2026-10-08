import Foundation
import Testing
@testable import DreadcastKit

@Suite("Geography")
struct GeoTests {
    @Test func coarsensToTwoDecimals() {
        let c = GeoCoordinate(latitude: 27.947_52, longitude: -82.458_43).coarsened
        #expect(c.latitude == 27.95)
        #expect(c.longitude == -82.46)
    }

    @Test func distanceAndBearing() {
        let tampa = GeoCoordinate(latitude: 27.95, longitude: -82.46)
        let orlando = GeoCoordinate(latitude: 28.54, longitude: -81.38)
        let miles = tampa.distanceMiles(to: orlando)
        #expect(miles > 70 && miles < 85)
        #expect(Compass.point(tampa.bearingDegrees(to: orlando)) == "ENE")
    }

    @Test func compassPoints() {
        #expect(Compass.point(0) == "N")
        #expect(Compass.point(359) == "N")
        #expect(Compass.point(225) == "SW")
        #expect(Compass.octant(100) == "E")
    }

    @Test func polygonContainmentExcludesHoles() {
        let outer = [(0.0, 0.0), (0, 10), (10, 10), (10, 0), (0, 0)].map { GeoCoordinate(latitude: $0.0, longitude: $0.1) }
        let hole = [(4.0, 4.0), (4, 6), (6, 6), (6, 4), (4, 4)].map { GeoCoordinate(latitude: $0.0, longitude: $0.1) }
        let polygon = GeoPolygon(outerRing: outer, holes: [hole])
        #expect(polygon.contains(GeoCoordinate(latitude: 2, longitude: 2)))
        #expect(!polygon.contains(GeoCoordinate(latitude: 5, longitude: 5)))
        #expect(!polygon.contains(GeoCoordinate(latitude: 12, longitude: 2)))
    }

    @Test func parsesCoordinateQueries() {
        #expect(PlaceService.parseCoordinates("27.95,-82.46") == GeoCoordinate(latitude: 27.95, longitude: -82.46))
        #expect(PlaceService.parseCoordinates("27.95 −82.46") == GeoCoordinate(latitude: 27.95, longitude: -82.46))
        #expect(PlaceService.parseCoordinates("Tampa") == nil)
        #expect(PlaceService.parseCoordinates("95,10") == nil)
    }

    @Test func placesStoreCoarseCoordinates() {
        let place = Place(name: "Test", coordinate: GeoCoordinate(latitude: 1.23456, longitude: 2.34567), source: .coordinates)
        #expect(place.coordinate == GeoCoordinate(latitude: 1.23, longitude: 2.35))
    }

    @Test func basemapLoadsAndKnowsLandFromWater() {
        let map = Basemap.shared
        #expect(map.land.count > 1000)
        #expect(map.cities.count > 1000)
        #expect(map.isLand(GeoCoordinate(latitude: 28.54, longitude: -81.38)))   // Orlando
        #expect(!map.isLand(GeoCoordinate(latitude: 27.0, longitude: -85.0)))   // Gulf of Mexico
        #expect(!map.isLand(GeoCoordinate(latitude: 26.95, longitude: -80.83))) // Lake Okeechobee
    }
}

@Suite("NWS alerts")
struct AlertTests {
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

    @Test func decodesSortsAndSkipsTests() throws {
        let alerts = try AlertService.decode(Data(Self.payload.utf8))
        #expect(alerts.count == 2)
        #expect(alerts[0].event == "Severe Thunderstorm Warning")
        #expect(alerts[0].level == .warning)
        #expect(alerts[0].severity == .severe)
        #expect(alerts[1].level == .watch)
        #expect(alerts[1].endsOrExpires == ISODate.parse("2026-10-06T08:00:00-04:00"))
    }

    @Test func eventNameDecidesTheHazard() throws {
        let alerts = try AlertService.decode(Data(Self.payload.utf8))
        // The description mentions a tornado, but the event is a thunderstorm warning.
        #expect(alerts[0].category == .thunderstorm)
        #expect(alerts[1].category == .flood)
    }

    @Test func severityOrdering() {
        #expect(WeatherAlert.Severity.extreme > .severe)
        #expect(WeatherAlert.Severity.minor > .unknown)
        #expect(WeatherAlert.Severity("SEVERE") == .severe)
    }

    @Test func severeOutlookRiskAtPoint() throws {
        let json = """
        {"type":"FeatureCollection","features":[
          {"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-90,25],[-80,25],[-80,35],[-90,35],[-90,25]]]},"properties":{"LABEL":"TSTM","EXPIRE_ISO":"2026-10-06T12:00:00+00:00"}},
          {"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-84,26],[-81,26],[-81,29],[-84,29],[-84,26]]]},"properties":{"LABEL":"SLGT"}}
        ]}
        """
        let outlook = try SevereOutlookService.decode(Data(json.utf8), now: Date())
        #expect(outlook.risk(at: GeoCoordinate(latitude: 27.95, longitude: -82.46)).risk == .slight)
        #expect(outlook.risk(at: GeoCoordinate(latitude: 33, longitude: -88)).risk == .thunder)
        #expect(outlook.risk(at: GeoCoordinate(latitude: 45, longitude: -100)).risk == SevereOutlook.Risk.none)
        #expect(SevereOutlook.Risk.slight.level == 2)
    }
}

@Suite("Open-Meteo")
struct WeatherTests {
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

    @Test func decodesAllSections() throws {
        let report = try WeatherService.decode(Data(Self.payload.utf8), coordinate: GeoCoordinate(latitude: 27.95, longitude: -82.46),
                                               units: .imperial, fetchedAt: Date(timeIntervalSince1970: 1_791_259_300))
        #expect(report.timeZoneIdentifier == "America/New_York")
        #expect(report.current.temperature == 71.2)
        #expect(report.current.weatherCode == 95)
        #expect(report.minutely.count == 2)
        #expect(report.hourly.count == 5)
        #expect(report.daily.count == 2)
        #expect(report.hourly[3].cape == 3280)
    }

    @Test func pressureTendencyAndCape() throws {
        let report = try WeatherService.decode(Data(Self.payload.utf8), coordinate: GeoCoordinate(latitude: 27.95, longitude: -82.46),
                                               units: .imperial, fetchedAt: Date())
        let now = Date(timeIntervalSince1970: 1_791_259_300)
        let tendency = try #require(report.pressureTendency(at: now))
        #expect(abs(tendency - (1004.2 - 1007.5)) < 0.001)
        #expect(report.cape(at: now) == 3280)
    }

    @Test func rejectsMalformedSeries() {
        let bad = Self.payload.replacingOccurrences(of: "\"temperature_2m\":[80,79,75,71,72]", with: "\"temperature_2m\":[80,79]")
        #expect(throws: DreadcastError.self) {
            _ = try WeatherService.decode(Data(bad.utf8), coordinate: GeoCoordinate(latitude: 0, longitude: 0), units: .imperial, fetchedAt: Date())
        }
    }

    @Test func requestURLUsesCoarseCoordinates() {
        let url = WeatherService.requestURL(for: GeoCoordinate(latitude: 27.947_52, longitude: -82.458_43), units: .metric).absoluteString
        #expect(url.contains("latitude=27.95"))
        #expect(url.contains("longitude=-82.46"))
        #expect(url.contains("temperature_unit=celsius"))
    }

    @Test func conditionWording() {
        #expect(WeatherCondition.description(95) == "Thunderstorm")
        #expect(WeatherCondition.description(82) == "Very heavy showers")
        #expect(WeatherCondition.isThunderstorm(96))
        #expect(!WeatherCondition.isPrecipitation(3))
    }
}

@Suite("Radar decoding")
struct RadarTests {
    // 4×2 indexed PNG with tRNS: transparent, 0x0088bf (23 dBZ rain), 0xffe000 (36 dBZ rain), 0x9fdfff (15 dBZ snow).
    // The second row uses the Up filter.
    static let indexedPNG = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAMAAABIdo1RAAAADFBMVEUAAAAAiL//4ACf3/9y9zMzAAAABHRSTlMA////sy1AiAAAABJJREFUeJxjYGBkYmZiZPj3HwADOwIHeu7YmwAAAABJRU5ErkJggg=="

    @Test func decodesIndexedPNGExactly() throws {
        let image = try PNGDecoder.decode(Data(base64Encoded: Self.indexedPNG)!)
        #expect(image.width == 4 && image.height == 2)
        #expect(image.rgba(x: 0, y: 0) & 0xFF == 0)
        #expect(image.rgba(x: 1, y: 0) == 0x0088_bfff)
        #expect(image.rgba(x: 2, y: 0) == 0xffe0_00ff)
        #expect(image.rgba(x: 0, y: 1) == 0x0088_bfff)
        #expect(image.rgba(x: 2, y: 1) & 0xFF == 0)
    }

    @Test func invertsUniversalBlueToReflectivity() throws {
        let image = try PNGDecoder.decode(Data(base64Encoded: Self.indexedPNG)!)
        let rain = try #require(UniversalBlueDecoder.reflectivity(rgba: image.rgba(x: 1, y: 0)))
        #expect(rain.dbz == 23 && !rain.snow)
        let heavier = try #require(UniversalBlueDecoder.reflectivity(rgba: image.rgba(x: 2, y: 0)))
        #expect(heavier.dbz == 36)
        let snow = try #require(UniversalBlueDecoder.reflectivity(rgba: image.rgba(x: 3, y: 0)))
        #expect(snow.dbz == 15 && snow.snow)
        #expect(UniversalBlueDecoder.reflectivity(rgba: image.rgba(x: 0, y: 0)) == nil)
    }

    @Test func colorTableRoundTrips() {
        for dbz in stride(from: 15, through: 60, by: 5) {
            let color = UniversalBlueDecoder.color(dbz: Double(dbz), snow: false)
            #expect(UniversalBlueDecoder.reflectivity(rgba: color)?.dbz == Int8(dbz))
        }
    }

    @Test func rejectsNonPNG() {
        #expect(throws: PNGDecoder.Failure.notPNG) { _ = try PNGDecoder.decode(Data("hello".utf8)) }
    }

    @Test func manifestValidation() throws {
        let good = """
        {"host":"https://tilecache.rainviewer.com","radar":{"past":[{"time":1791258000,"path":"/v2/radar/abc"},{"time":1791257400,"path":"/v2/radar/def"}]}}
        """
        let manifest = try RainViewerService.decodeManifest(Data(good.utf8), now: Date())
        #expect(manifest.frames.count == 2)
        #expect(manifest.frames.first!.time < manifest.frames.last!.time)
        let url = RainViewerService.tileURL(host: manifest.host, frame: manifest.frames[0], zoom: 7, x: 34, y: 54)!
        #expect(url.absoluteString == "https://tilecache.rainviewer.com/v2/radar/def/512/7/34/54/2/0_1.png")

        let hostile = good.replacingOccurrences(of: "https://tilecache.rainviewer.com", with: "http://example.com")
        #expect(throws: DreadcastError.self) { _ = try RainViewerService.decodeManifest(Data(hostile.utf8), now: Date()) }
    }

    @Test func viewportRoundTrip() {
        let viewport = RadarViewport(center: GeoCoordinate(latitude: 27.95, longitude: -82.46), rangeMiles: 35, width: 72, height: 48)
        let c = viewport.coordinate(x: 10, y: 20)
        let p = viewport.pixel(for: c)
        #expect(abs(p.x - 10) < 0.01 && abs(p.y - 20) < 0.01)
        #expect(abs(viewport.milesPerPixel - 70.0 / 72) < 1e-9)
    }

    @Test func zoomFollowsRange() {
        let loader = RadarLoader()
        let close = RadarViewport(center: GeoCoordinate(latitude: 28, longitude: -82), rangeMiles: 15, width: 100, height: 60)
        let wide = RadarViewport(center: GeoCoordinate(latitude: 28, longitude: -82), rangeMiles: 300, width: 100, height: 60)
        #expect(loader.zoom(for: close) == 7)
        #expect(loader.zoom(for: wide) < 6)
    }

    @Test func palettesInterpolate() {
        #expect(RadarPalette.dreadcast.rgb(dbz: 35) == 0xd6e990)
        #expect(RadarPalette.classic.rgb(dbz: 0) == 0x397da9)
        #expect(RadarPalette.viridis.rgb(dbz: 80) == 0xfde725)
        #expect(RadarPalette.rainviewer.rgb(dbz: 23) == 0x0088bf)
    }

    @Test func rainRates() {
        #expect(RainRate.Intensity(dbz: 45) == .heavy)
        #expect(RainRate.Intensity(dbz: 10) == RainRate.Intensity.none)
        let rate = RainRate.millimetersPerHour(dbz: 40)
        #expect(rate > 11 && rate < 12.5)
    }
}

@Suite("Nowcast")
struct NowcastTests {
    /// A storm blob moving east three pixels per ten-minute frame.
    static func fields(viewport: RadarViewport, startX: Double, step: Double) -> [ReflectivityField] {
        (0..<4).map { frame in
            let cx = startX + step * Double(frame), cy = Double(viewport.height) / 2
            var dbz = [Int8](repeating: ReflectivityField.none, count: viewport.width * viewport.height)
            for y in 0..<viewport.height {
                for x in 0..<viewport.width {
                    let d2 = pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)
                    let value = 50 * exp(-d2 / 30)
                    if value >= 10 { dbz[y * viewport.width + x] = Int8(value) }
                }
            }
            return ReflectivityField(width: viewport.width, height: viewport.height,
                                     time: Date(timeIntervalSince1970: 1_791_259_200 + Double(frame) * 600),
                                     dbz: dbz, snow: [Bool](repeating: false, count: dbz.count))
        }
    }

    @Test func approachingStormArrives() throws {
        let viewport = RadarViewport(center: GeoCoordinate(latitude: 30, longitude: -90), rangeMiles: 40, width: 80, height: 80)
        let nowcast = Nowcaster.forecast(fields: Self.fields(viewport: viewport, startX: 10, step: 3), viewport: viewport,
                                         now: Date(timeIntervalSince1970: 1_791_261_100))
        let bearing = try #require(nowcast.motionBearing)
        #expect(abs(bearing - 90) < 15)
        let mph = try #require(nowcast.motionMPH)
        #expect(mph > 13 && mph < 23)
        let arrival = try #require(nowcast.arrivalMinutes)
        #expect(arrival > 30 && arrival < 75)
        #expect(!nowcast.isRainingNow)
        #expect(nowcast.cells.first?.maxDBZ ?? 0 >= 40)
    }

    @Test func departingStormNeverArrives() {
        let viewport = RadarViewport(center: GeoCoordinate(latitude: 30, longitude: -90), rangeMiles: 40, width: 80, height: 80)
        let nowcast = Nowcaster.forecast(fields: Self.fields(viewport: viewport, startX: 52, step: 3), viewport: viewport)
        #expect(nowcast.arrivalMinutes == nil)
        #expect(nowcast.nearestEchoBearing.map { abs($0 - 90) < 20 } == true)
    }

    @Test func emptySkyIsQuiet() {
        let viewport = RadarViewport(center: GeoCoordinate(latitude: 30, longitude: -90), rangeMiles: 40, width: 40, height: 40)
        let empty = (0..<3).map { i in
            ReflectivityField(width: 40, height: 40, time: Date(timeIntervalSince1970: Double(i) * 600),
                              dbz: [Int8](repeating: ReflectivityField.none, count: 1600), snow: [Bool](repeating: false, count: 1600))
        }
        let nowcast = Nowcaster.forecast(fields: empty, viewport: viewport)
        #expect(nowcast.arrivalMinutes == nil)
        #expect(nowcast.motionMPH == nil)
        #expect(nowcast.nearestEchoMiles == nil)
        #expect(nowcast.cells.isEmpty)
    }
}

@Suite("Lightning, outlook and hazards")
struct OutlookTests {
    @Test func decodesXweather() throws {
        let now = Date(timeIntervalSince1970: 1_791_259_800)
        let json = """
        {"success":true,"error":null,"response":[
          {"id":"1","loc":{"long":-82.5,"lat":27.9},"ob":{"timestampMS":1791259700000,"pulse":{"type":"cg","peakamp":-21000}}},
          {"id":"2","loc":{"long":-82.4,"lat":28.0},"ob":{"timestamp":1791258000,"pulse":{"type":"ic"}}}
        ]}
        """
        let strikes = try XweatherLightningService.decode(Data(json.utf8), now: now)
        #expect(strikes.count == 1) // the second is older than 20 minutes
        #expect(strikes[0].kind == .cloudToGround)
        #expect(strikes[0].ageBand(at: now) == .newest)
        let empty = try XweatherLightningService.decode(Data(#"{"success":false,"error":{"code":"warn_no_data"},"response":[]}"#.utf8), now: now)
        #expect(empty.isEmpty)
    }

    @Test func ageBands() {
        #expect(LightningAgeBand(age: 100) == .newest)
        #expect(LightningAgeBand(age: 500) == .warm)
        #expect(LightningAgeBand(age: 1100) == .oldest)
    }

    @Test func decodesKpAndScales() throws {
        let json = """
        [{"time_tag":"2026-10-05T00:00:00","kp":3.0,"observed":"observed","noaa_scale":null},
         {"time_tag":"2026-10-06T21:00:00","kp":5.33,"observed":"predicted","noaa_scale":"G1"}]
        """
        let samples = try OutlookDecoder.solar(Data(json.utf8))
        #expect(samples.count == 2)
        #expect(samples[1].stormScale == "G1")
        #expect(SolarOutlook.geomagneticScale(kp: 5.33) == "G1")
        #expect(SolarOutlook.geomagneticScale(kp: 4) == nil)
    }

    @Test func auroraReadingNearLocation() throws {
        let json = """
        {"Observation Time":"2026-10-05T23:00:00Z","Forecast Time":"2026-10-05T23:45:00Z",
         "coordinates":[[278,28,0],[278,38,12],[278,45,40],[100,28,90]]}
        """
        let reading = try OutlookDecoder.aurora(Data(json.utf8)).reading(at: GeoCoordinate(latitude: 28, longitude: -82))
        #expect(reading.probability == 0)
        #expect(reading.poleward == 12)
    }

    @Test func meteorCalendarEnds() {
        let zone = TimeZone(identifier: "America/New_York")!
        #expect(!MeteorCalendar.upcoming(at: Date(timeIntervalSince1970: 1_791_259_200), timeZone: zone).isEmpty)
        #expect(MeteorCalendar.upcoming(at: Date(timeIntervalSince1970: 1_900_000_000), timeZone: zone).isEmpty)
    }

    @Test func moonPhase() {
        // 2026-10-26 is a full moon.
        let full = LunarPhase(at: ISODate.parse("2026-10-26T04:00:00Z")!)
        #expect(full.illumination > 0.95)
        #expect(full.name == .fullMoon)
    }

    @Test func radioAbsorptionGrid() throws {
        let text = """
        # Product Valid At : 2026-10-05 22:00 UTC
        #
          -10   0   10
        -----------------
          10 |  0  0  0
          20 |  0  5  0
          30 |  0  0  0
        """
        let snapshot = try HazardDecoder.radioDisruption(Data(text.utf8), now: ISODate.parse("2026-10-05T22:30:00Z")!)
        #expect(snapshot.grid?.value(at: GeoCoordinate(latitude: 20, longitude: 0)) == 5)
        #expect(snapshot.grid?.value(at: GeoCoordinate(latitude: 10, longitude: -10)) == 0)
    }
}

@Suite("Tropical storms")
struct TropicalTests {
    /// The NHC summary layer as GeoJSON: one storm at its current position and 12 hours on.
    static func payload(name: String, development: String) -> Data {
        func feature(tau: Int, longitude: Double) -> String {
            #"{"type":"Feature","geometry":{"type":"Point","coordinates":[\#(longitude),25.0]},"properties":{"stormname":"\#(name)","stormtype":"TS","advdate":"1000 PM CDT Wed Oct 07 2026","tau":\#(tau),"tcdvlp":"\#(development)","maxwind":55,"binnumber":"AT4"}}"#
        }
        return Data(#"{"type":"FeatureCollection","features":[\#(feature(tau: 12, longitude: -86.0)),\#(feature(tau: 0, longitude: -85.0))]}"#.utf8)
    }

    @Test func keepsTheCurrentPositionAndNamesTheStormOnce() throws {
        let storms = try TropicalService.decode(Self.payload(name: "Tropical Storm Isaias", development: "Tropical Storm"))
        let storm = try #require(storms.first)
        #expect(storms.count == 1)
        #expect(storm.longitude == -85.0)
        #expect(storm.title == "Tropical Storm Isaias")
        let bare = try #require(try TropicalService.decode(Self.payload(name: "Isaias", development: "Tropical Storm")).first)
        #expect(bare.title == "Tropical Storm Isaias")
        let hurricane = try #require(try TropicalService.decode(Self.payload(name: "Hurricane Rachel", development: "Hurricane")).first)
        #expect(hurricane.title == "Hurricane Rachel")
    }
}
