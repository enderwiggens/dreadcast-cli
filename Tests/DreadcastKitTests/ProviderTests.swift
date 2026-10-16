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

@Suite("Weather from the Dreadcast API")
struct WeatherTests {
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

    static let tampa = GeoCoordinate(latitude: 27.95, longitude: -82.46)
    static let now = Date(timeIntervalSince1970: 1_791_259_300)

    static func report(current: String = current, forecast: String = forecast, units: UnitSystem = .imperial) throws -> WeatherReport {
        try WeatherService.decode(current: Data(current.utf8), forecast: Data(forecast.utf8), coordinate: tampa, units: units, now: now)
    }

    @Test func decodesAllSections() throws {
        let report = try Self.report()
        #expect(report.timeZoneIdentifier == "America/New_York" && report.utcOffsetSeconds == -14400)
        #expect(report.current.temperature == 71.2 && report.current.weatherCode == 95 && report.current.isDay)
        #expect(report.current.time == ISODate.parse("2026-10-06T04:00:00Z"))
        #expect(report.minutely.count == 2 && report.minutely[1].precipitation == 0.05)
        #expect(report.hourly.count == 5 && report.hourly[3].cape == 3280)
        #expect(report.daily.count == 2 && report.daily[0].high == 88 && report.daily[1].sunset == ISODate.parse("2026-10-06T22:30:00Z"))
        // Daily dates are local midnights in the place's zone.
        #expect(report.daily[0].date == ISODate.parse("2026-10-05T04:00:00Z"))
        #expect(report.fetchedAt == ISODate.parse("2026-10-05T18:00:00Z") && report.stale == nil)
    }

    @Test func pressureTendencyAndCape() throws {
        let report = try Self.report()
        let tendency = try #require(report.pressureTendency(at: Self.now))
        #expect(abs(tendency - (1004.2 - 1007.5)) < 0.001)
        #expect(report.cape(at: Self.now) == 3280)
    }

    @Test func valuesThatCantBeRightAreLeftOut() throws {
        let odd = Self.current.replacingOccurrences(of: #""relative_humidity":82"#, with: #""relative_humidity":140"#)
            .replacingOccurrences(of: #""weather_code":95,"is_day""#, with: #""weather_code":250,"is_day""#)
            .replacingOccurrences(of: #""wind_speed":14"#, with: #""wind_speed":-3"#)
        let report = try Self.report(current: odd)
        #expect(report.current.humidity == nil && report.current.weatherCode == nil && report.current.windSpeed == nil)
        #expect(report.current.temperature == 71.2)
        let stale = try Self.report(current: Self.current.replacingOccurrences(of: #""stale":false"#, with: #""stale":true"#))
        #expect(stale.stale == true)
    }

    @Test func rejectsAnswersItCantTrust() {
        func rejects(current: String = Self.current, forecast: String = Self.forecast, units: UnitSystem = .imperial) -> Bool {
            (try? Self.report(current: current, forecast: forecast, units: units)) == nil
        }
        #expect(!rejects())
        // Other units than asked for, or than the other answer.
        #expect(rejects(units: .metric))
        #expect(rejects(forecast: Self.forecast.replacingOccurrences(of: #""precipitation":"inch""#, with: #""precipitation":"mm""#)))
        #expect(rejects(current: "not json"))
        #expect(rejects(current: Self.current.replacingOccurrences(of: #""time":"2026-10-06T04:00:00Z","interval"#, with: #""time":"soon","interval"#)))
        #expect(rejects(forecast: Self.forecast.replacingOccurrences(of: #""date":"2026-10-06""#, with: #""date":"2026-10-05""#)))
        #expect(rejects(forecast: Self.forecast.replacingOccurrences(of: #""date":"2026-10-06""#, with: #""date":"Tuesday""#)))
        #expect(rejects(forecast: Self.forecast.replacingOccurrences(of: "2026-10-06T05:00:00Z", with: "2026-10-06T00:00:00Z")))
    }

    @Test func aTimeZoneThatIsntOneFallsBackToTheOffset() throws {
        let odd = Self.forecast.replacingOccurrences(of: #""timezone":"America/New_York""#, with: #""timezone":"\u001b[2J""#)
        let report = try Self.report(current: Self.current.replacingOccurrences(of: #""timezone":"America/New_York""#, with: #""timezone":null"#),
                                     forecast: odd)
        #expect(report.timeZone.secondsFromGMT(for: Self.now) == -14400)
        #expect(!report.timeZoneIdentifier.contains("\u{1B}"))
    }

    @Test func requestsUseCoarseCoordinatesAndUnits() throws {
        let api = try #require(URL(string: "https://api.dreadcast.app"))
        let url = try #require(WeatherService.url(api, "v1/weather/current", coordinate: GeoCoordinate(latitude: 27.947_52, longitude: -82.458_43), units: .metric))
        #expect(url.absoluteString == "https://api.dreadcast.app/v1/weather/current?lat=27.95&lon=-82.46&temperature_unit=celsius&wind_speed_unit=kmh&precipitation_unit=mm")
    }

    @Test func airQualityIsAPointReading() throws {
        let air = #"{"current":{"time":"2026-10-06T04:00:00Z","interval_seconds":3600,"us_aqi":161.4,"pm2_5":61.0,"pm10":null,"ozone":-1,"dust":12.5}}"#
        let reading = try AirQualityService.decode(Data(air.utf8), now: Self.now)
        #expect(reading.usAQI == 161 && reading.category == "Unhealthy")
        #expect(reading.pm2_5 == 61 && reading.pm10 == nil && reading.ozone == nil && reading.dust == 12.5)
        // Without an AQI there's no reading, but the dust still counts.
        let noIndex = Data(air.replacingOccurrences(of: "161.4", with: "null").utf8)
        #expect(throws: DreadcastError.self) { _ = try AirQualityService.decode(noIndex, now: Self.now) }
        #expect(try AirQualityService.current(noIndex, now: Self.now).dust == 12.5)
        // An hour far ahead isn't a current reading.
        #expect(throws: DreadcastError.self) {
            _ = try AirQualityService.current(Data(air.replacingOccurrences(of: "2026-10-06T04:00:00Z", with: "2026-10-07T04:00:00Z").utf8), now: Self.now)
        }
    }

    @Test func placeSearchResultsAreLabeledAndCleaned() throws {
        let results = #"{"results":[{"name":"Tampa","latitude":27.94752,"longitude":-82.45843,"country_code":"us","country":"United States","admin1":"Florida","timezone":"America/New_York"},{"name":"Lis\u001b[2Jbon","latitude":38.72,"longitude":-9.13,"country_code":null,"country":"Portugal","admin1":null,"timezone":null},{"name":"Nowhere","latitude":95,"longitude":0}],"source":{}}"#
        let places = try PlaceService.places(Data(results.utf8))
        #expect(places.map(\.name) == ["Tampa, FL", "Lis[2Jbon, Portugal"])
        #expect(places[0].countryCode == "US" && places[0].coordinate == GeoCoordinate(latitude: 27.95, longitude: -82.46))
        #expect(places[1].timeZone == nil && places[1].countryCode == nil)
    }

    @Test func conditionWording() {
        #expect(WeatherCondition.description(95) == "Thunderstorm")
        #expect(WeatherCondition.description(82) == "Very heavy showers")
        #expect(WeatherCondition.isThunderstorm(96))
        #expect(!WeatherCondition.isPrecipitation(3))
    }
}

/// The forecast model's rain timing, for places no radar reaches.
@Suite("Model rain")
struct ModelRainTests {
    /// 18:35Z on October 5, 2026: inside the 15-minute step that ends at 18:45.
    static let now = Date(timeIntervalSince1970: 1_791_225_300)

    /// A report whose 15-minute steps end every quarter hour from 18:45, in inches.
    static func report(_ precipitation: [Double]) throws -> WeatherReport {
        let steps = precipitation.enumerated().map { index, value in
            let time = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(1_791_225_900 + index * 900)))
            return #"{"time":"\#(time)","precipitation":\#(value),"weather_code":\#(value > 0 ? 61 : 3)}"#
        }
        let current = WeatherTests.current.replacingOccurrences(
            of: #""minutely_15":[{"time":"2026-10-06T04:00:00Z","precipitation":0.0,"weather_code":95},{"time":"2026-10-06T04:15:00Z","precipitation":0.05,"weather_code":95}]"#, with: #""minutely_15":[\#(steps.joined(separator: ","))]"#)
        return try WeatherService.decode(current: Data(current.utf8), forecast: Data(WeatherTests.forecast.utf8),
                                         coordinate: GeoCoordinate(latitude: 35.68, longitude: 139.69), units: .imperial, now: now)
    }

    @Test func timesTheNextTwoHours() throws {
        // Dry, then rain from 19:00 (heavy 19:15–19:30), dry again from 19:45. The step
        // starting 20:45 is past two hours.
        let model = try #require(ModelRain(report: try Self.report([0, 0, 0.02, 0.15, 0.03, 0, 0, 0, 0, 0.5]), now: Self.now))
        #expect(!model.rainingNow)
        #expect(model.arrivalMinutes == 25 && model.endMinutes == 70)
        #expect(model.heavyMinutes == 15)
        #expect(model.steps.count == 9 && model.coversTwoHours)
        #expect(model.precipitation(atMinute: 30) == 0.02)
        #expect(model.precipitation(atMinute: 200) == nil)
        #expect(model.equivalentDBZ(atMinute: 0) == 0)
        #expect((model.equivalentDBZ(atMinute: 45) ?? 0) > Nowcaster.heavyThreshold)
    }

    @Test func rainNowEndsOrRunsPastTheSteps() throws {
        let easing = try #require(ModelRain(report: try Self.report([0.1, 0.1, 0]), now: Self.now))
        #expect(easing.rainingNow && easing.arrival == nil)
        #expect(easing.endMinutes == 25)
        // Three steps reach 19:15, not two hours: the timing says where it stops.
        #expect(!easing.coversTwoHours)
        #expect(easing.until == Self.now.addingTimeInterval(40 * 60))
        let steady = try #require(ModelRain(report: try Self.report(Array(repeating: 0.05, count: 12)), now: Self.now))
        #expect(steady.rainingNow && steady.end == nil && steady.coversTwoHours)
        #expect(steady.heavyMinutes == 0)
    }

    @Test func oldReadingsHaveNoTiming() throws {
        let report = try Self.report([0, 0.1])
        #expect(ModelRain(report: report, now: Self.now.addingTimeInterval(4 * 3600)) == nil)
        // The fixture's own steps are hours from this clock.
        #expect(ModelRain(report: try WeatherTests.report(), now: Self.now) == nil)
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

    @Test func rejectsNonPNG() {
        #expect(throws: PNGDecoder.Failure.notPNG) { _ = try PNGDecoder.decode(Data("hello".utf8)) }
    }

    @Test func viewportRoundTrip() {
        let viewport = RadarViewport(center: GeoCoordinate(latitude: 27.95, longitude: -82.46), rangeMiles: 35, width: 72, height: 48)
        let c = viewport.coordinate(x: 10, y: 20)
        let p = viewport.pixel(for: c)
        #expect(abs(p.x - 10) < 0.01 && abs(p.y - 20) < 0.01)
        #expect(abs(viewport.milesPerPixel - 70.0 / 72) < 1e-9)
    }

    @Test func zoomFollowsRange() {
        let close = RadarViewport(center: GeoCoordinate(latitude: 28, longitude: -82), rangeMiles: 15, width: 100, height: 60)
        let wide = RadarViewport(center: GeoCoordinate(latitude: 28, longitude: -82), rangeMiles: 300, width: 100, height: 60)
        // Radar's 512-pixel tiles stop at zoom 8, and closer views stretch them.
        #expect(RadarLoader().dreadcastZoom(for: close) == 8)
        #expect(RadarLoader().dreadcastZoom(for: wide) == 3)
        // The satellite's 256-pixel tiles stop at zoom 6.
        #expect(RadarLoader.zoom(for: close, tileSize: 256, maximum: 6) == 6)
        #expect(RadarLoader.zoom(for: wide, tileSize: 256, maximum: 6) == 4)
    }

    @Test func palettesInterpolate() {
        #expect(RadarPalette.dreadcast.rgb(dbz: 35) == 0xd6e990)
        #expect(RadarPalette.classic.rgb(dbz: 0) == 0x397da9)
        #expect(RadarPalette.viridis.rgb(dbz: 80) == 0xfde725)
        #expect(RadarPalette(rawValue: "rainviewer") == nil)
    }

    @Test func rainRates() {
        #expect(RainRate.Intensity(dbz: 45) == .heavy)
        #expect(RainRate.Intensity(dbz: 10) == RainRate.Intensity.none)
        let rate = RainRate.millimetersPerHour(dbz: 40)
        #expect(rate > 11 && rate < 12.5)
        #expect(abs(RainRate.dbz(millimetersPerHour: rate) - 40) < 1e-9)
        #expect(RainRate.dbz(millimetersPerHour: 0) == 0)
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
