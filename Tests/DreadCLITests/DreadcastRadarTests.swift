import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import DreadTerminal
@testable import DreadcastKit
@testable import DreadCLI

/// A manifest in the Dreadcast API's shape (dreadcast-server `docs/API.md`,
/// `/v2/radar/latest`): the contiguous US and Europe at zooms 3–8, frames four minutes
/// apart. Every tile is `n` except those listed as stored, and Europe scans every eight
/// minutes, so it repeats a scan in every other frame.
enum RadarAPIFixture {
    struct RegionSpec: Sendable {
        let id: String
        let name: String
        let bounds: [Double]
        let source: [String: String]
        let delayedAfter: Int
    }

    static let conus = RegionSpec(id: "conus", name: "Contiguous U.S.", bounds: [-130, 20, -60, 55],
                                  source: ["name": "NOAA MRMS", "url": "https://www.nssl.noaa.gov/projects/mrms/",
                                           "license": "Public domain (U.S. Government data)"], delayedAfter: 600)
    static let europe = RegionSpec(id: "europe", name: "Europe", bounds: [-25, 34, 33, 72.5],
                                   source: ["name": "EUMETNET OPERA", "url": "https://www.eumetnet.eu/observations/weather-radar-network/",
                                            "license": "CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/)"], delayedAfter: 1200)
    static let tileHost = "tiles.dreadcast.app"
    static let zooms = 3...8

    static func levels(_ region: RegionSpec) -> [(z: Int, x: [Int], y: [Int])] {
        zooms.map { z in
            let b = region.bounds
            let northwest = WebMercator.pixel(GeoCoordinate(latitude: b[3], longitude: b[0]), zoom: z, tileSize: 1)
            let southeast = WebMercator.pixel(GeoCoordinate(latitude: b[1], longitude: b[2]), zoom: z, tileSize: 1)
            return (z, [Int(northwest.x), Int(southeast.x)], [Int(northwest.y), Int(southeast.y)])
        }
    }

    /// Run-length tile states for a region: `stored` tiles are `t`, `missing` tiles `m`,
    /// and the rest `n`.
    static func states(_ region: RegionSpec, stored: Set<String>, missing: Set<String> = []) -> String {
        var letters: [Character] = []
        for level in levels(region) {
            for x in level.x[0]...level.x[1] {
                for y in level.y[0]...level.y[1] {
                    let key = "\(level.z)/\(x)/\(y)"
                    letters.append(stored.contains(key) ? "t" : missing.contains(key) ? "m" : "n")
                }
            }
        }
        var encoded = ""
        var index = 0
        while index < letters.count {
            var run = 1
            while index + run < letters.count, letters[index + run] == letters[index] { run += 1 }
            encoded += "\(letters[index])\(run)"
            index += run
        }
        return encoded
    }

    static func id(_ prefix: String, _ date: Date) -> String { DreadcastRadarManifest.frameID(prefix: prefix, for: date) }
    static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func json(newest: Date, frames count: Int = 3, regions: [RegionSpec] = [conus, europe], stored: Set<String> = [],
                     missing: Set<String> = [], status: String = "live", host: String = tileHost, scheme: String = "https",
                     satellite: Bool = false, tamper: (inout [String: Any]) -> Void = { _ in }) -> Data {
        let times = (0..<count).map { newest.addingTimeInterval(Double($0 - count + 1) * 240) }
        // Europe's scan for a frame: the newest on its eight-minute schedule.
        func europeScan(_ time: Date) -> Date { times.last { $0 <= time && Int(newest.timeIntervalSince($0) / 240) % 2 == 0 } ?? times[0] }
        func scanTime(_ region: RegionSpec, _ frame: Date) -> Date { region.id == "europe" ? europeScan(frame) : frame }
        var object: [String: Any] = [
            "status": status,
            "newest_observed_at": iso(times.last!),
            "product": "MergedBaseReflectivityQC_00.50",
            "encoding": "mrms-rg8-v1",
            "tile_size": 512,
            "regions": regions.map { region -> [String: Any] in
                ["id": region.id, "name": region.name, "status": status, "delayed_after_seconds": region.delayedAfter,
                 "newest_observed_at": iso(scanTime(region, times.last!)), "source": region.source,
                 "bounds": region.bounds, "cell_degrees": 0.01, "min_zoom": zooms.lowerBound, "max_zoom": zooms.upperBound,
                 "tile_grid": levels(region).map { ["z": $0.z, "x": $0.x, "y": $0.y] }]
            },
            "frames": times.map { time -> [String: Any] in
                var scans: [String: Any] = [:]
                for region in regions {
                    let scanned = scanTime(region, time)
                    let scanID = id("mrms", scanned)
                    scans[region.id] = ["id": scanID, "observed_at": iso(scanned),
                                        "flag_observed_at": region.id == "europe" ? NSNull() : iso(scanned) as Any,
                                        "tile_url": "\(scheme)://\(host)/mrms/snapshots/\(scanID)/\(region.id)/{z}/{x}/{y}.png",
                                        "tile_states": states(region, stored: stored, missing: missing)]
                }
                let frameTime = regions.map { scanTime($0, time) }.max()!
                return ["id": id("radar", frameTime), "observed_at": iso(frameTime), "regions": scans]
            },
            "source": ["name": "NOAA MRMS", "provider": "noaa-mrms"],
            "a_future_field": true,
        ]
        if satellite { object["satellite"] = satelliteBlock(newest) }
        tamper(&object)
        return try! JSONSerialization.data(withJSONObject: object)
    }

    /// A 512-pixel tile with the same red and green value everywhere.
    static func tile(red: UInt8, green: UInt8) -> Data {
        PNGEncoder.encode(Raster(width: 512, height: 512, fill: UInt32(red) << 16 | UInt32(green) << 8))!
    }

    /// The red value for a reflectivity: dBZ = (R − 2) / 2 − 32.
    static func red(dbz: Double) -> UInt8 { UInt8((dbz + 32) * 2 + 2) }

    /// The tile under a place at the zoom a view of it uses.
    static func tileKey(_ place: Place, viewport: RadarViewport) -> String {
        let zoom = RadarLoader().dreadcastZoom(for: viewport, minimum: zooms.lowerBound)
        let p = WebMercator.pixel(place.coordinate, zoom: zoom, tileSize: 1)
        return "\(zoom)/\(Int(p.x))/\(Int(p.y))"
    }

    /// Where the stub serves satellite tiles.
    static let satellitePath = "api.dreadcast.app/v2/radar/satellite.png"

    /// Blend IDs, newest first: 20 and 30 minutes before `newest`, so the newest frames
    /// have none of their own yet.
    static func satelliteSnapshots(_ newest: Date) -> [Int] {
        let base = Int(newest.timeIntervalSince1970)
        return [base - 1200, base - 1800]
    }

    /// The API's `satellite` block (dreadcast-server `docs/API.md#global-satellite-rain`).
    static func satelliteBlock(_ newest: Date) -> [String: Any] {
        ["provider": "noaa", "description": "Rain-rate estimates from geostationary satellites",
         "source": ["name": "NOAA Enterprise Rain Rate", "url": "https://www.ospo.noaa.gov/products/atmosphere/err/",
                    "license": "Public domain (U.S. Government data); credit NOAA"],
         "encoding": "rainbow-dbz-u8", "tile_size": 256, "max_zoom": 6,
         "tile_path": "v2/radar/satellite.png?snapshot={snapshot}&z={z}&x={x}&y={y}",
         "snapshots": satelliteSnapshots(newest).map { ["id": $0, "observed_at": iso(Date(timeIntervalSince1970: Double($0)))] }]
    }

    /// A 256-pixel satellite tile with one reflectivity everywhere: red is dBZ + 32.
    static func satelliteTile(dbz: Int) -> Data {
        PNGEncoder.encode(Raster(width: 256, height: 256, fill: UInt32(dbz + 32) << 16))!
    }

    /// The command fixture's conditions, with 15-minute steps (in inches) ending every
    /// quarter hour from 18:45Z on October 5, 2026.
    static func weather(minutely precipitation: [Double]) -> String {
        let steps = precipitation.enumerated().map { index, value in
            #"{"time":"\#(iso(Date(timeIntervalSince1970: Double(1_791_225_900 + index * 900))))","precipitation":\#(value),"weather_code":\#(value > 0 ? 61 : 3)}"#
        }
        return WeatherFixture.current.replacingOccurrences(
            of: #""minutely_15":[{"time":"2026-10-06T04:00:00Z","precipitation":0.0,"weather_code":95},{"time":"2026-10-06T04:15:00Z","precipitation":0.05,"weather_code":95}]"#, with: #""minutely_15":[\#(steps.joined(separator: ","))]"#)
    }

    static let now = ISODate.parse("2026-10-07T12:00:00Z")!
    static let tampa = SceneTests.tampa
    static let london = Place(name: "London", coordinate: GeoCoordinate(latitude: 51.51, longitude: -0.13), countryCode: "GB", source: .search)
    static let tokyo = Place(name: "Tokyo", coordinate: GeoCoordinate(latitude: 35.68, longitude: 139.69), countryCode: "JP", source: .search)
}

@Suite("Dreadcast radar API")
struct DreadcastRadarTests {
    typealias F = RadarAPIFixture

    @Test func decodesTheContract() throws {
        let manifest = try DreadcastRadarManifest.decode(F.json(newest: F.now), now: F.now)
        #expect(manifest.regions.map(\.id) == ["conus", "europe"])
        #expect(manifest.frames.count == 3)
        #expect(manifest.frames.last?.observedAt == F.now)
        #expect(manifest.regions[0].levels.map(\.z) == Array(3...8))
        let conus = try #require(manifest.region(for: F.tampa.coordinate))
        let europe = try #require(manifest.region(for: F.london.coordinate))
        #expect(conus.id == "conus" && europe.id == "europe")
        #expect(manifest.region(for: F.tokyo.coordinate) == nil)

        // Each region keeps its own time: Europe repeats a scan, so its loop is shorter
        // and timed by its own scans.
        #expect(manifest.frames(for: conus).map(\.observedAt) == manifest.frames.map(\.observedAt))
        #expect(manifest.frames(for: europe).map(\.observedAt) == [F.now.addingTimeInterval(-480), F.now])

        // Europe's source publishes more slowly, so it's delayed later.
        #expect(!conus.isDelayed(at: F.now) && !europe.isDelayed(at: F.now))
        #expect(conus.isDelayed(at: F.now.addingTimeInterval(11 * 60)))
        #expect(!europe.isDelayed(at: F.now.addingTimeInterval(11 * 60)))
        #expect(manifest.usable(at: F.now.addingTimeInterval(2 * 3600)) != nil)
        #expect(manifest.usable(at: F.now.addingTimeInterval(4 * 3600)) == nil)
        let delayed = try DreadcastRadarManifest.decode(F.json(newest: F.now, status: "delayed"), now: F.now)
        #expect(delayed.regions.allSatisfy { $0.isDelayed(at: F.now) })

        // Credits follow the regions in view, and name a license that asks for it.
        #expect(manifest.credits(south: 27, north: 29, west: -83, east: -82) == ["NOAA MRMS"])
        #expect(manifest.credits(south: 51, north: 52, west: -1, east: 1) == ["EUMETNET OPERA (CC BY 4.0, resampled)"])
        #expect(manifest.credits(south: 35, north: 36, west: 139, east: 140).isEmpty)
    }

    /// A region more than three hours behind is dropped, and the frames only it moved on
    /// with it; the rest of the loop stays.
    @Test func regionsTooOldToShowAreDropped() throws {
        let old = F.now.addingTimeInterval(-4 * 3600)
        let data = F.json(newest: F.now) { object in
            var regions = object["regions"] as! [[String: Any]]
            regions[1]["newest_observed_at"] = F.iso(old)
            object["regions"] = regions
            var frames = object["frames"] as! [[String: Any]]
            for index in frames.indices {
                var scans = frames[index]["regions"] as! [String: Any]
                let id = F.id("mrms", old)
                scans["europe"] = ["id": id, "observed_at": F.iso(old), "flag_observed_at": NSNull(),
                                   "tile_url": "https://\(F.tileHost)/mrms/snapshots/\(id)/europe/{z}/{x}/{y}.png",
                                   "tile_states": F.states(F.europe, stored: [])]
                frames[index]["regions"] = scans
            }
            object["frames"] = frames
        }
        let manifest = try DreadcastRadarManifest.decode(data, now: F.now)
        #expect(manifest.region(for: F.london.coordinate)?.id == "europe")
        let usable = try #require(manifest.usable(at: F.now))
        #expect(usable.regions.map(\.id) == ["conus"])
        #expect(usable.frames.count == 3 && usable.frames.allSatisfy { $0.scans.keys.sorted() == ["conus"] })
        #expect(usable.region(for: F.london.coordinate) == nil)
        #expect(usable.region(for: F.tampa.coordinate)?.id == "conus")
    }

    /// The Mac app's rules: nothing in a manifest becomes a request until it checks out.
    @Test func rejectsManifestsThatDontCheckOut() {
        func rejects(_ data: Data, allowLoopback: Bool = false) -> Bool {
            (try? DreadcastRadarManifest.decode(data, now: F.now, allowLoopback: allowLoopback)) == nil
        }
        func region(_ index: Int, _ change: @escaping (inout [String: Any]) -> Void) -> Data {
            F.json(newest: F.now) { object in
                var regions = object["regions"] as! [[String: Any]]
                change(&regions[index])
                object["regions"] = regions
            }
        }
        func scan(_ change: @escaping (inout [String: Any]) -> Void) -> Data {
            F.json(newest: F.now) { object in
                var frames = object["frames"] as! [[String: Any]]
                var scans = frames[0]["regions"] as! [String: Any]
                var conus = scans["conus"] as! [String: Any]
                change(&conus)
                scans["conus"] = conus
                frames[0]["regions"] = scans
                object["frames"] = frames
            }
        }
        #expect(!rejects(F.json(newest: F.now)))
        #expect(rejects(Data("not json".utf8)))
        #expect(rejects(F.json(newest: F.now, host: "radar.example.com")))
        #expect(rejects(F.json(newest: F.now, host: "dreadcast.app.example.com")))
        #expect(rejects(F.json(newest: F.now, scheme: "http")))
        #expect(rejects(F.json(newest: F.now, host: "127.0.0.1", scheme: "http")))
        #expect(!rejects(F.json(newest: F.now, host: "127.0.0.1", scheme: "http"), allowLoopback: true))
        #expect(!rejects(F.json(newest: F.now, host: "nyc3.digitaloceanspaces.com")))
        #expect(rejects(F.json(newest: F.now) { $0["encoding"] = "png-colors" }))
        #expect(rejects(F.json(newest: F.now) { $0["status"] = "maybe" }))
        #expect(rejects(F.json(newest: F.now) { $0["newest_observed_at"] = "2026-10-07T11:00:00Z" }))
        #expect(rejects(F.json(newest: F.now) { $0["regions"] = [] }))
        #expect(rejects(F.json(newest: F.now) { object in
            object["frames"] = Array((object["frames"] as! [[String: Any]]).reversed())
        }))
        #expect(rejects(F.json(newest: F.now) { object in
            var frames = object["frames"] as! [[String: Any]]
            frames[0]["id"] = "radar-20000101t000000"
            object["frames"] = frames
        }))
        // Regions: names the terminal shows can't carry escape sequences.
        #expect(rejects(region(1) { $0["name"] = "Europe\u{1B}[2J" }))
        #expect(rejects(region(1) { $0["source"] = ["name": "OPERA\u{07}", "license": "CC BY 4.0"] }))
        #expect(rejects(region(0) { $0["id"] = "CONUS" }))
        #expect(rejects(region(0) { $0["max_zoom"] = 9 }))
        #expect(rejects(region(0) { $0["delayed_after_seconds"] = 5 }))
        #expect(rejects(region(0) { $0["bounds"] = [-60, 20, -130, 55] }))
        #expect(rejects(region(0) { region in
            var grid = region["tile_grid"] as! [[String: Any]]
            grid.removeLast()
            region["tile_grid"] = grid
        }))
        #expect(!rejects(region(1) { $0["source"] = nil }))
        // Scans.
        #expect(rejects(scan { $0["tile_states"] = "t1" }))
        #expect(rejects(scan { $0["id"] = "mrms-20000101t000000" }))
        #expect(rejects(scan { $0["tile_url"] = "https://\(F.tileHost)/mrms/snapshots/other/conus/{z}/{x}/{y}.png" }))
        #expect(rejects(scan { $0["flag_observed_at"] = "2026-10-07T10:00:00Z" }))
        #expect(rejects(F.json(newest: F.now) { object in
            var frames = object["frames"] as! [[String: Any]]
            var scans = frames[0]["regions"] as! [String: Any]
            scans["mars"] = scans["conus"]
            frames[0]["regions"] = scans
            object["frames"] = frames
        }))
    }

    @Test func tileStatesExpandAndLookUp() throws {
        #expect(DreadcastRadarManifest.expand("m2t3n1").map { String(decoding: $0, as: UTF8.self) } == "mmtttn")
        #expect(DreadcastRadarManifest.expand("") == [])
        #expect(DreadcastRadarManifest.expand("t") == nil)
        #expect(DreadcastRadarManifest.expand("x3") == nil)
        #expect(DreadcastRadarManifest.expand("3t") == nil)
        #expect(DreadcastRadarManifest.expand("t9000") == nil)

        // Every tile's state lands where the grid order puts it.
        let level = F.levels(F.conus)[3]
        let stored: Set<String> = ["\(level.z)/\(level.x[0] + 1)/\(level.y[0] + 2)", "\(level.z)/\(level.x[1])/\(level.y[1])"]
        let manifest = try DreadcastRadarManifest.decode(F.json(newest: F.now, stored: stored), now: F.now)
        let conus = manifest.regions[0]
        let scan = try #require(manifest.frames[0].scans["conus"])
        let states = try #require(DreadcastRadarManifest.expand(scan.tileStates))
        for x in level.x[0]...level.x[1] {
            for y in level.y[0]...level.y[1] {
                let expected = stored.contains("\(level.z)/\(x)/\(y)") ? DreadcastRadarManifest.t : DreadcastRadarManifest.n
                #expect(conus.state(states, z: level.z, x: x, y: y) == expected)
            }
        }
        #expect(conus.state(states, z: level.z, x: level.x[1] + 1, y: level.y[0]) == DreadcastRadarManifest.m)
        #expect(conus.state(states, z: 9, x: 0, y: 0) == DreadcastRadarManifest.m)
    }

    @Test func tilesHoldMeasurements() throws {
        let tile = RadarTileDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: F.red(dbz: 40), green: 3)))
        #expect(tile.dbz[0] == 40 && tile.snow[0])
        let rain = RadarTileDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: F.red(dbz: 52.5), green: 6)))
        #expect(rain.dbz[1000] == 53 && !rain.snow[1000])
        // Europe has no precipitation type: green is 255, never snow.
        let europe = RadarTileDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: F.red(dbz: 30), green: 255)))
        #expect(europe.dbz[0] == 30 && !europe.snow[0])
        let clear = RadarTileDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: 1, green: 0)))
        #expect(clear.dbz.allSatisfy { $0 == ReflectivityField.none } && clear.isFullyCovered)
        let uncovered = RadarTileDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: 0, green: 0)))
        #expect(uncovered.dbz.allSatisfy { $0 == RadarTileDecoder.uncovered } && !uncovered.isFullyCovered)
    }

    /// Where regions overlap, each pixel comes from the first region with coverage there.
    @Test func overlappingRegionsTakeTheFirstWithCoverage() {
        typealias Tile = RadarTileDecoder.Tile
        let first = Tile(size: 2, dbz: [30, RadarTileDecoder.uncovered, ReflectivityField.none, RadarTileDecoder.uncovered],
                         snow: [false, false, false, false])
        let second = Tile(size: 2, dbz: [50, 45, 50, RadarTileDecoder.uncovered], snow: [false, true, false, false])
        let drawn = first.filling(from: second)
        #expect(drawn.dbz == [30, 45, ReflectivityField.none, RadarTileDecoder.uncovered])
        #expect(drawn.snow == [false, true, false, false])
        #expect(!drawn.isFullyCovered)
    }

    @Test func theAPIIsUsedByDefault() throws {
        let unset = try SceneTests.context()
        #expect(unset.dreadcastAPI == URL(string: "https://api.dreadcast.app"))
        let set = try SceneTests.context()
        set.config.apiURL = "https://api.dreadcast.app/"
        #expect(set.dreadcastAPI == URL(string: "https://api.dreadcast.app"))
        set.config.apiURL = "off"
        #expect(set.dreadcastAPI == nil)
        // A config saved with RainViewer's palette and source still loads.
        let old = try JSONDecoder().decode(Config.self, from: Data(#"{"version":1,"palette":"rainviewer","radarSource":"rainviewer"}"#.utf8))
        #expect(old.palette == .dreadcast)
    }

    /// Checked as the Mac app checks it: anything off leaves satellite rain out, and the
    /// radar still loads.
    @Test func satelliteRainIsListedAndChecked() throws {
        let manifest = try DreadcastRadarManifest.decode(F.json(newest: F.now, satellite: true), now: F.now)
        let satellite = try #require(manifest.satellite)
        let ids = F.satelliteSnapshots(F.now)
        #expect(satellite.snapshots.map(\.id) == ids)
        #expect(satellite.maximumZoom == 6 && satellite.source.credit == "NOAA Enterprise Rain Rate")
        // Frames NOAA hasn't covered yet hold the newest blend up to their time.
        let newest = try #require(manifest.frames.last)
        #expect(newest.satellite == nil && manifest.satelliteSnapshot(for: newest)?.id == ids[0])
        // A frame the server pairs with a blend shows that one; an unlisted blend is dropped.
        func frame(_ value: Any) throws -> DreadcastRadarManifest.Frame {
            let data = F.json(newest: F.now, satellite: true) { object in
                var frames = object["frames"] as! [[String: Any]]
                frames[0]["satellite"] = value
                object["frames"] = frames
            }
            return try DreadcastRadarManifest.decode(data, now: F.now).frames[0]
        }
        let paired = try frame(ids[1])
        #expect(paired.satellite == ids[1] && manifest.satelliteSnapshot(for: paired)?.id == ids[1])
        #expect(try frame(ids[1] - 600).satellite == nil)
        #expect(try frame("soon").satellite == nil)

        func block(_ change: @escaping (inout [String: Any]) -> Void) throws -> DreadcastRadarManifest {
            try DreadcastRadarManifest.decode(F.json(newest: F.now, satellite: true) { object in
                var block = object["satellite"] as! [String: Any]
                change(&block)
                object["satellite"] = block
            }, now: F.now)
        }
        #expect(try block { $0["encoding"] = "png-colors" }.satellite == nil)
        #expect(try block { $0["tile_path"] = "https://example.com/{z}/{x}/{y}.png" }.satellite == nil)
        #expect(try block { $0["snapshots"] = Array(($0["snapshots"] as! [[String: Any]]).reversed()) }.satellite == nil)
        #expect(try block { $0["snapshots"] = [["id": ids[0], "observed_at": F.iso(F.now)]] }.satellite == nil)
        #expect(try block { $0["snapshots"] = [] }.satellite == nil)
        // A source that can't be shown is credited by name instead.
        #expect(try block { $0["source"] = ["name": "NOAA\u{1B}[2J"] }.satellite?.source.credit == "NOAA Enterprise Rain Rate")
        let broken = try DreadcastRadarManifest.decode(F.json(newest: F.now) { $0["satellite"] = "soon" }, now: F.now)
        #expect(broken.satellite == nil && broken.frames.count == 3)
    }

    /// dbz_u8: red holds dBZ + 32, with snow in its top bit, and alpha 0 is no data.
    @Test func satelliteTilesHoldEstimates() {
        let pixels: [UInt8] = [67, 0, 0, 255, 12, 0, 0, 255, 72 | 128, 0, 0, 255, 90, 0, 0, 0]
        let tile = RadarTileDecoder.decodeSatelliteTile(RGBAImage(width: 2, height: 2, pixels: pixels))
        #expect(tile.dbz == [35, ReflectivityField.none, 40, RadarTileDecoder.uncovered])
        #expect(tile.snow == [false, false, true, false])
        #expect(RadarTileDecoder.drySatelliteTile.dbz.allSatisfy { $0 == ReflectivityField.none })
    }

    @Test func satelliteEstimatesFillOnlyWhereNoRadarReaches() {
        let none = ReflectivityField.none
        var radar = ReflectivityField(width: 3, height: 1, time: F.now, dbz: [30, none, none], snow: [false, false, false],
                                      covered: [true, true, false])
        let estimates = ReflectivityField(width: 3, height: 1, time: F.now, dbz: [45, 45, 25], snow: [false, false, true],
                                          covered: [true, true, true])
        let filled = radar.fill(from: estimates)
        #expect(filled)
        #expect(radar.dbz == [30, none, 25] && radar.snow == [false, false, true])
        #expect(radar.isCovered(x: 2, y: 0))
        #expect(radar.hasRadar(x: 0, y: 0) && radar.hasRadar(x: 1, y: 0) && !radar.hasRadar(x: 2, y: 0))
        // Radar everywhere: nothing to fill.
        var full = estimates
        let refilled = full.fill(from: radar)
        #expect(!refilled && full.estimated == nil && full.hasRadar(x: 2, y: 0))
    }

    @Test func apiURLsAreHTTPSOrLocal() {
        #expect(Context.apiURL("https://api.dreadcast.app/")?.absoluteString == "https://api.dreadcast.app")
        #expect(Context.apiURL("http://localhost:3000")?.absoluteString == "http://localhost:3000")
        #expect(Context.apiURL("http://127.0.0.1:3000/")?.absoluteString == "http://127.0.0.1:3000")
        #expect(Context.apiURL("http://api.dreadcast.app") == nil)
        #expect(Context.apiURL("https://user:secret@api.dreadcast.app") == nil)
        #expect(Context.apiURL("https://api.dreadcast.app/?key=1") == nil)
        #expect(Context.apiURL("ftp://api.dreadcast.app") == nil)
        #expect(Context.apiURL("off") == nil && Context.apiURL("") == nil)
    }

    /// The animation redraws a fixed number of lines, so the footer never wraps, and the
    /// frame's age always shows.
    @Test func theFooterFitsOneLine() {
        let credit = "EUMETNET OPERA (CC BY 4.0, resampled) · NOAA Enterprise Rain Rate, 11:20 PM"
        #expect(RadarCommand.footer(credit: "NOAA MRMS", ago: "5 min ago", delayed: false, width: 97)
            == "NOAA MRMS · Natural Earth · latest frame 5 min ago")
        // At 100 columns, "latest frame" goes so the satellite blend's time stays.
        #expect(RadarCommand.footer(credit: credit, ago: "5 min ago", delayed: false, width: 97) == credit + " · 5 min ago")
        #expect(RadarCommand.footer(credit: credit, ago: "25 min ago", delayed: true, width: 110) == credit + " · radar delayed · 25 min ago")
        let tight = RadarCommand.footer(credit: credit, ago: "25 min ago", delayed: true, width: 80)
        #expect(TextWidth.of(tight) <= 80 && tight.hasPrefix("EUMETNET OPERA (CC BY 4.0, resampled)")
            && tight.hasSuffix(" · radar delayed · 25 min ago"))
    }

    @Test func framesArePickedNewestFirstAndSpacedOut() {
        let times = (0..<8).map { F.now.addingTimeInterval(Double($0 - 7) * 240) }
        let every = Context.pick(times, time: { $0 }, count: 4, spacing: 0)
        #expect(every == Array(times.suffix(4)))
        let spaced = Context.pick(times, time: { $0 }, count: 4, spacing: 480)
        #expect(spaced == [times[1], times[3], times[5], times[7]])
        #expect(Context.pick([F.now], time: { $0 }, count: 4, spacing: 480) == [F.now])
    }
}

/// End to end against stubbed API and CDN responses. Part of the serialized command
/// suite because the stub's routes are shared.
extension CommandTests {
    /// A context whose requests go to the stub, with the API set.
    static func radarContext(_ environment: [String: String]) -> Context {
        var environment = environment
        environment["DREADCAST_API_URL"] = "https://api.dreadcast.app"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProvider.self]
        let terminal = TerminalInfo(isOutputTTY: false, isInputTTY: false, columns: 100, rows: 40, colorMode: .none,
                                    graphics: .none, program: nil, insideMultiplexer: false, reduceMotion: false)
        return Context(arguments: Arguments(command: "radar"), environment: environment, terminal: terminal,
                       http: HTTPClient(session: URLSession(configuration: configuration)))
    }

    /// Serves `manifest` from the API and `tile` for every tile request.
    static func serveRadar(_ manifest: Data, tile: Data?) {
        StubProvider.reset(["api.dreadcast.app": (200, String(decoding: manifest, as: UTF8.self)),
                            RadarAPIFixture.tileHost: (200, "")])
        StubProvider.lock.withLock { StubProvider.tileBody = tile }
    }

    @Test func radarComesFromTheAPIsTiles() async throws {
        typealias F = RadarAPIFixture
        let ctx = Self.radarContext(try await Self.home(location: "27.95,-82.46"))
        defer { StubProvider.lock.withLock { StubProvider.tileBody = nil } }

        // Store only the tile under Tampa at the zoom a 35-mile view uses.
        let viewport = RadarViewport(center: F.tampa.coordinate, rangeMiles: 35, width: 80, height: 60)
        let stored: Set<String> = [F.tileKey(F.tampa, viewport: viewport)]
        let newest = Date()
        Self.serveRadar(F.json(newest: newest, stored: stored), tile: F.tile(red: F.red(dbz: 45), green: 6))

        let loop = try await ctx.radarLoop(for: F.tampa, viewport: viewport, frames: 2)
        #expect(loop.credit == "NOAA MRMS")
        #expect(loop.coversPlace && !loop.delayed)
        #expect(loop.fields.count == 2)
        let center = try #require(loop.fields.last?.value(x: 40, y: 30))
        #expect(center == 45)
        #expect(loop.newestFrame?.hasPrefix(F.id("radar", newest) + "|") == true)
        #expect(await ctx.newestRadarFrame() == loop.newestFrame)

        // Only stored tiles are requested; listed empty tiles never are.
        let tileRequests = StubProvider.seen.filter { $0.url?.host == F.tileHost }.compactMap { $0.url?.path }
        #expect(!tileRequests.isEmpty)
        #expect(tileRequests.allSatisfy { path in stored.contains { path.hasSuffix("/conus/\($0).png") } })
        #expect(StubProvider.seen.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("dreadcast-cli/") == true })
    }

    @Test func europeRadarIsTimedAndCreditedByItsRegion() async throws {
        typealias F = RadarAPIFixture
        let ctx = Self.radarContext(try await Self.home(location: "51.51,-0.13"))
        defer { StubProvider.lock.withLock { StubProvider.tileBody = nil } }
        let viewport = RadarViewport(center: F.london.coordinate, rangeMiles: 35, width: 80, height: 60)
        let newest = Date()
        Self.serveRadar(F.json(newest: newest, frames: 3, stored: [F.tileKey(F.london, viewport: viewport)]),
                        tile: F.tile(red: F.red(dbz: 30), green: 255))

        let loop = try await ctx.radarLoop(for: F.london, viewport: viewport, frames: 8)
        #expect(loop.credit == "EUMETNET OPERA (CC BY 4.0, resampled)")
        // Europe scanned twice in the three frames, so the loop has its two scans.
        #expect(loop.fields.map(\.time) == [newest.addingTimeInterval(-480), newest].map { ISODate.parse(F.iso($0))! })
        #expect(loop.fields.last?.value(x: 40, y: 30) == 30)
        #expect(loop.fields.last?.isSnow(x: 40, y: 30) == false)
        #expect(StubProvider.seen.contains { $0.url?.path.contains("/europe/") == true })
    }

    /// Serves satellite tiles from the API's path: `tile` with `status`.
    static func serveSatellite(_ tile: Data?, status: Int = 200) {
        StubProvider.lock.withLock {
            StubProvider.routes[RadarAPIFixture.satellitePath] = (status, "")
            StubProvider.binaries[RadarAPIFixture.satellitePath] = tile
        }
    }

    static var satelliteRequests: [URL] { StubProvider.seen.compactMap(\.url).filter { $0.path == "/v2/radar/satellite.png" } }

    /// Where no region reaches the view, the loop is NOAA's satellite blends, each at its
    /// own time.
    @Test func satelliteEstimatesDrawBeyondTheRegions() async throws {
        typealias F = RadarAPIFixture
        let ctx = Self.radarContext(try await Self.home(location: "35.68,139.69"))
        defer { StubProvider.lock.withLock { StubProvider.tileBody = nil; StubProvider.binaries = [:] } }
        let newest = Date()
        Self.serveRadar(F.json(newest: newest, satellite: true), tile: nil)
        Self.serveSatellite(F.satelliteTile(dbz: 35))

        let viewport = RadarViewport(center: F.tokyo.coordinate, rangeMiles: 35, width: 40, height: 30)
        let loop = try await ctx.radarLoop(for: F.tokyo, viewport: viewport, frames: 2)
        let ids = F.satelliteSnapshots(newest)
        #expect(loop.fields.map(\.time) == ids.reversed().map { Date(timeIntervalSince1970: Double($0)) })
        #expect(loop.fields.allSatisfy { $0.value(x: 20, y: 15) == 35 && !$0.hasRadar(x: 20, y: 15) })
        #expect(!loop.coversPlace && !loop.delayed)
        #expect(loop.credit == "NOAA Enterprise Rain Rate (satellite estimates)")
        #expect(await ctx.newestRadarFrame() == loop.newestFrame)
        // From the API at the satellite's own zoom; never the regions' tiles.
        let requests = Self.satelliteRequests
        #expect(!requests.isEmpty && requests.allSatisfy { $0.host == "api.dreadcast.app" })
        let query = requests.compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
        #expect(Set(query.compactMap { $0.first { $0.name == "snapshot" }?.value }) == Set(ids.map(String.init)))
        #expect(query.allSatisfy { $0.first { $0.name == "z" }?.value == "6" })
        #expect(!StubProvider.seen.contains { $0.url?.host == F.tileHost })
    }

    /// With `satellite.tile_url` on the radar tiles' own origin, satellite rain comes from
    /// the CDN, and rows wholly past 70°N or 60°S, which have no tiles there, aren't asked
    /// for. A CDN that fails hands the tile back to the API.
    @Test func satelliteTilesComeFromTheCDNWhenNamed() async throws {
        typealias F = RadarAPIFixture
        let cdn = "https://\(F.tileHost)/mrms/satellite/{snapshot}/{z}/{x}/{y}.png"
        func manifest(_ url: String) -> Data {
            F.json(newest: Date(), satellite: true) { object in
                var block = object["satellite"] as! [String: Any]
                block["tile_url"] = url
                object["satellite"] = block
            }
        }
        #expect(try DreadcastRadarManifest.decode(manifest(cdn), now: Date()).satellite?.tileURL == cdn)
        for other in ["https://elsewhere.example/mrms/satellite/{snapshot}/{z}/{x}/{y}.png",
                      "https://\(F.tileHost)/mrms/satellite/{snapshot}/{z}/{x}/{y}.png?x=1",
                      "https://\(F.tileHost)/other/satellite/{snapshot}/{z}/{x}/{y}.png"] {
            let decoded = try DreadcastRadarManifest.decode(manifest(other), now: Date())
            #expect(decoded.satellite != nil && decoded.satellite?.tileURL == nil)
        }
        #expect(DreadcastRadarManifest.Satellite.rowHasData(z: 6, y: 32))
        #expect(!DreadcastRadarManifest.Satellite.rowHasData(z: 6, y: 0))
        #expect(!DreadcastRadarManifest.Satellite.rowHasData(z: 6, y: 63))

        defer { StubProvider.lock.withLock { StubProvider.tileBody = nil; StubProvider.binaries = [:] } }
        let viewport = RadarViewport(center: F.tokyo.coordinate, rangeMiles: 35, width: 40, height: 30)
        let ctx = Self.radarContext(try await Self.home(location: "35.68,139.69"))
        Self.serveRadar(manifest(cdn), tile: F.satelliteTile(dbz: 35))
        let loop = try await ctx.radarLoop(for: F.tokyo, viewport: viewport, frames: 2)
        #expect(loop.fields.allSatisfy { $0.value(x: 20, y: 15) == 35 })
        #expect(Self.satelliteRequests.isEmpty)
        #expect(StubProvider.seen.contains { $0.url?.host == F.tileHost && $0.url?.path.hasPrefix("/mrms/satellite/") == true })

        let fallback = Self.radarContext(try await Self.home(location: "35.68,139.69"))
        Self.serveRadar(manifest(cdn), tile: nil)
        StubProvider.lock.withLock { StubProvider.routes[F.tileHost] = (403, "") }
        Self.serveSatellite(F.satelliteTile(dbz: 35))
        let recovered = try await fallback.radarLoop(for: F.tokyo, viewport: viewport, frames: 2)
        #expect(recovered.fields.allSatisfy { $0.value(x: 20, y: 15) == 35 })
        #expect(!Self.satelliteRequests.isEmpty)
    }


    /// the loop is the satellite blends too.
    @Test func satelliteLoopsWhereNoRadarReachesTheView() async throws {
        typealias F = RadarAPIFixture
        let ctx = Self.radarContext(try await Self.home(location: "41.90,12.50"))
        defer { StubProvider.lock.withLock { StubProvider.tileBody = nil; StubProvider.binaries = [:] } }
        let rome = Place(name: "Rome", coordinate: GeoCoordinate(latitude: 41.90, longitude: 12.50), countryCode: "IT", source: .search)
        let viewport = RadarViewport(center: rome.coordinate, rangeMiles: 35, width: 40, height: 30)
        let newest = Date()
        let data = F.json(newest: newest, missing: [F.tileKey(rome, viewport: viewport)], satellite: true)
        let manifest = try DreadcastRadarManifest.decode(data, now: newest)
        #expect(!RadarLoader().radarReaches(manifest, frame: manifest.frames[2], viewport: viewport))
        Self.serveRadar(data, tile: nil)
        Self.serveSatellite(F.satelliteTile(dbz: 35))

        let loop = try await ctx.radarLoop(for: rome, viewport: viewport, frames: 2)
        #expect(loop.fields.map(\.time) == F.satelliteSnapshots(newest).reversed().map { Date(timeIntervalSince1970: Double($0)) })
        #expect(loop.credit == "NOAA Enterprise Rain Rate (satellite estimates)")
        #expect(!loop.coversPlace && !loop.delayed)
        #expect(!StubProvider.seen.contains { $0.url?.host == F.tileHost })

        // A stored tile in view whose radar covers none of the view's pixels: the same,
        // once the tile shows it.
        let stored = Self.radarContext(try await Self.home(location: "41.90,12.50"))
        Self.serveRadar(F.json(newest: newest, stored: [F.tileKey(rome, viewport: viewport)], satellite: true), tile: F.tile(red: 0, green: 0))
        Self.serveSatellite(F.satelliteTile(dbz: 35))
        let gap = try await stored.radarLoop(for: rome, viewport: viewport, frames: 2)
        #expect(gap.credit == "NOAA Enterprise Rain Rate (satellite estimates)")
        #expect(StubProvider.seen.contains { $0.url?.host == F.tileHost })
    }

    /// Right after NOAA's blend comes back from an outage the API lists one, and a view
    /// only the estimates reach shows it rather than failing (October 16, 2026).
    @Test func oneSatelliteBlendStillShows() async throws {
        typealias F = RadarAPIFixture
        let ctx = Self.radarContext(try await Self.home(location: "35.68,139.69"))
        defer { StubProvider.lock.withLock { StubProvider.tileBody = nil; StubProvider.binaries = [:] } }
        let viewport = RadarViewport(center: F.tokyo.coordinate, rangeMiles: 35, width: 40, height: 30)
        let newest = Date()
        Self.serveRadar(F.json(newest: newest, satellite: true) { object in
            var block = object["satellite"] as! [String: Any]
            block["snapshots"] = Array((block["snapshots"] as! [[String: Any]]).prefix(1))
            object["satellite"] = block
        }, tile: nil)
        Self.serveSatellite(F.satelliteTile(dbz: 35))

        let loop = try await ctx.radarLoop(for: F.tokyo, viewport: viewport, frames: 8)
        #expect(loop.fields.map(\.time) == [Date(timeIntervalSince1970: Double(F.satelliteSnapshots(newest)[0]))])
        #expect(loop.fields.first?.value(x: 20, y: 15) == 35)
        #expect(loop.credit == "NOAA Enterprise Rain Rate (satellite estimates)")
    }

    /// Inside a region's bounds but outside its radars, as in Italy for Europe: estimates
    /// fill the place's pixels and nothing the region covers.
    @Test func satelliteEstimatesFillGapsInARegion() async throws {
        typealias F = RadarAPIFixture
        let ctx = Self.radarContext(try await Self.home(location: "51.51,-0.13"))
        defer { StubProvider.lock.withLock { StubProvider.tileBody = nil; StubProvider.binaries = [:] } }
        let viewport = RadarViewport(center: F.london.coordinate, rangeMiles: 35, width: 40, height: 30)
        Self.serveRadar(F.json(newest: Date(), missing: [F.tileKey(F.london, viewport: viewport)], satellite: true), tile: nil)
        Self.serveSatellite(F.satelliteTile(dbz: 35))

        let loop = try await ctx.radarLoop(for: F.london, viewport: viewport, frames: 2)
        let newest = try #require(loop.fields.last)
        #expect(newest.value(x: 20, y: 15) == 35 && !newest.hasRadar(x: 20, y: 15))
        #expect(!loop.coversPlace)
        // The region's covered tiles keep their radar, here no echo.
        let radar = (0..<newest.height).flatMap { y in (0..<newest.width).map { (x: $0, y: y) } }.filter { newest.hasRadar(x: $0.x, y: $0.y) }
        #expect(!radar.isEmpty && radar.allSatisfy { newest.value(x: $0.x, y: $0.y) == nil })
        #expect(loop.credit.hasPrefix("EUMETNET OPERA (CC BY 4.0, resampled) · NOAA Enterprise Rain Rate, "))
        // Rain timing uses radar only, so it doesn't time London's rain from the estimates.
        let nowcast = await ctx.nowcast(F.london)
        #expect(nowcast.outsideCoverage && nowcast.value == nil)
    }

    /// A tile the API answers 204 for is dry. When estimates fail, the regions draw alone,
    /// and a view only the estimates reach says they're unavailable.
    @Test func satelliteFailuresLeaveTheRadar() async throws {
        typealias F = RadarAPIFixture
        let ctx = Self.radarContext(try await Self.home(location: "35.68,139.69"))
        defer { StubProvider.lock.withLock { StubProvider.tileBody = nil; StubProvider.binaries = [:] } }
        let viewport = RadarViewport(center: F.tokyo.coordinate, rangeMiles: 35, width: 40, height: 30)
        Self.serveRadar(F.json(newest: Date(), satellite: true), tile: nil)
        Self.serveSatellite(nil, status: 204)
        let dry = try await ctx.radarLoop(for: F.tokyo, viewport: viewport, frames: 2)
        #expect(dry.fields.last?.isCovered(x: 20, y: 15) == true && dry.fields.last?.value(x: 20, y: 15) == nil)
        #expect(dry.credit == "NOAA Enterprise Rain Rate (satellite estimates)")

        // Fresh caches, since the dry tiles and the manifest are kept.
        let fresh = Self.radarContext(try await Self.home(location: "35.68,139.69"))
        Self.serveRadar(F.json(newest: Date(), satellite: true), tile: nil)
        Self.serveSatellite(nil, status: 500)
        await #expect(throws: (any Error).self) { try await fresh.radarLoop(for: F.tokyo, viewport: viewport, frames: 2) }

        let london = Self.radarContext(try await Self.home(location: "51.51,-0.13"))
        let view = RadarViewport(center: F.london.coordinate, rangeMiles: 35, width: 40, height: 30)
        Self.serveRadar(F.json(newest: Date(), missing: [F.tileKey(F.london, viewport: view)], satellite: true), tile: nil)
        Self.serveSatellite(nil, status: 500)
        let alone = try await london.radarLoop(for: F.london, viewport: view, frames: 2)
        #expect(alone.fields.last?.isCovered(x: 20, y: 15) == false)
        #expect(alone.credit == "EUMETNET OPERA (CC BY 4.0, resampled)")
    }

    /// Rain timing names the radar it came from everywhere it's shown: the eta header and
    /// frames line, the quick look's sources line, and both commands' JSON.
    @Test func rainTimingCreditsTheAPIsRadar() async throws {
        typealias F = RadarAPIFixture
        let env = try await Self.home()
        let now = ISODate.parse("2026-10-05T18:30:00Z")!
        let place = Place(name: "Tampa", coordinate: GeoCoordinate(latitude: 27.95, longitude: -82.46), countryCode: "US", source: .coordinates)
        let viewport = RadarViewport(center: place.coordinate, rangeMiles: Context.nowcastRangeMiles,
                                     width: Context.nowcastViewportSize, height: Context.nowcastViewportSize)
        var routes = Self.online
        routes["api.dreadcast.app"] = (200, String(decoding: F.json(newest: now, stored: [F.tileKey(place, viewport: viewport)], satellite: true),
                                               as: UTF8.self))
        routes[F.tileHost] = (200, "")
        StubProvider.lock.withLock { StubProvider.tileBody = F.tile(red: F.red(dbz: 45), green: 6) }
        defer { StubProvider.lock.withLock { StubProvider.tileBody = nil } }

        let pretty = try await Self.run(["eta", "--pretty"], environment: env, routes: routes)
        #expect(pretty.code == .ok)
        #expect(pretty.out.contains("NOAA MRMS"))
        #expect(!pretty.out.uppercased().contains("RAINVIEWER"))
        let eta = try Self.json(try await Self.run(["eta", "--json"], environment: env, routes: routes).out)
        #expect(eta["source"] as? String == "dreadcast")
        #expect(eta["credit"] as? String == "NOAA MRMS")

        let quick = try await Self.run(["now", "--pretty"], environment: env, routes: routes)
        #expect(quick.out.contains("NOAA MRMS"))
        #expect(!quick.out.uppercased().contains("RAINVIEWER"))
        let now_ = try Self.json(try await Self.run(["now", "--json"], environment: env, routes: routes).out)
        let nowcast = try #require(now_["nowcast"] as? [String: Any])
        #expect(nowcast["source"] as? String == "dreadcast")
        #expect(nowcast["credit"] as? String == "NOAA MRMS")
        // Timing reads radar alone, never satellite estimates.
        #expect(Self.satelliteRequests.isEmpty)
    }

    /// Where no radar reaches, rain timing comes from the forecast model, labeled as the
    /// model's everywhere it shows; it isn't reported as a failure.
    @Test func rainTimingBeyondTheRegionsComesFromTheModel() async throws {
        typealias F = RadarAPIFixture
        let env = try await Self.home(location: "35.68,139.69")
        var routes = Self.online
        routes[Self.current] = (200, F.weather(minutely: [0, 0, 0.02, 0.15, 0.03, 0, 0, 0, 0]))
        routes["api.dreadcast.app"] = (200, String(decoding: F.json(newest: ISODate.parse("2026-10-05T18:30:00Z")!, satellite: true), as: UTF8.self))

        let json = try await Self.run(["eta", "--json"], environment: env, routes: routes)
        #expect(json.code == .ok)
        let eta = try Self.json(json.out)
        #expect(eta["schema"] as? String == "dreadcast.eta/1")
        #expect(eta["source"] as? String == "model" && eta["credit"] as? String == "Open-Meteo")
        #expect(eta["units"] as? String == "imperial" && eta["confidence"] as? String == "low")
        #expect(eta["raining"] as? Bool == false)
        #expect(eta["arrivalMinutes"] as? Int == 30 && eta["endMinutes"] as? Int == 75 && eta["heavyMinutes"] as? Int == 15)
        #expect(eta["trend"] == nil && (eta["frames"] as? [Any])?.isEmpty == true)
        let steps = try #require(eta["steps"] as? [[String: Any]])
        #expect(steps.count == 8 && steps[2]["minutes"] as? Int == 30 && steps[2]["precipitation"] as? Double == 0.02)
        #expect(Self.satelliteRequests.isEmpty)

        let plain = try await Self.run(["eta", "--plain"], environment: env, routes: routes)
        #expect(plain.code == .ok)
        #expect(plain.out.contains("The forecast model expects rain from") && plain.out.contains("No radar reaches"))
        let pretty = try await Self.run(["eta", "--pretty"], environment: env, routes: routes)
        #expect(pretty.out.contains("FORECAST MODEL") && pretty.out.contains("Heavy for ~15 min"))

        let radar = try await Self.run(["radar", "--plain"], environment: env, routes: routes)
        #expect(radar.code == .unavailable && radar.err.contains("No radar reaches"))

        let now = try await Self.run(["now", "--plain"], environment: env, routes: routes)
        #expect(now.out.contains("Rain: rain from ~") && now.out.contains("(forecast)"))

        let systems = try Self.json(try await Self.run(["systems", "--json"], environment: env, routes: routes).out)
        let rows = try #require(systems["systems"] as? [[String: Any]])
        let row = try #require(rows.first { $0["name"] as? String == "No radar here" })
        #expect(row["state"] as? String == "NO RADAR")
        #expect((row["detail"] as? [String])?.contains { $0.hasPrefix("The forecast model expects rain from") } == true)
        let unavailable = (systems["unavailable"] as? [[String: Any]] ?? []).compactMap { $0["source"] as? String }
        #expect(!unavailable.contains("radar"))
    }

    /// Radar comes only from the API: when it's down or turned off, there's none, and
    /// nothing else is asked instead.
    @Test func radarIsUnavailableWithoutTheAPI() async throws {
        let ctx = Self.radarContext(try await Self.home(location: "27.95,-82.46"))
        StubProvider.reset(["api.dreadcast.app": (503, #"{"error":{"code":"radar_unavailable"}}"#)])
        let viewport = RadarViewport(center: RadarAPIFixture.tampa.coordinate, rangeMiles: 35, width: 40, height: 30)
        await #expect(throws: (any Error).self) { try await ctx.radarLoop(for: RadarAPIFixture.tampa, viewport: viewport, frames: 2) }
        #expect(Set(StubProvider.seen.compactMap { $0.url?.host }) == ["api.dreadcast.app"])

        let env = try await Self.home()
        #expect(try await Self.run(["config", "set", "api-url", "off", "--plain"], environment: env).code == .ok)
        let eta = try await Self.run(["eta", "--plain"], environment: env)
        #expect(eta.code == .unavailable && eta.err.contains("api-url off"))
        #expect(!StubProvider.seen.contains { $0.url?.host == "api.dreadcast.app" })
    }

    @Test func radarSettingsValidate() async throws {
        let env = try await Self.home()
        #expect(try await Self.run(["config", "set", "api-url", "https://api.dreadcast.app/", "--plain"], environment: env).code == .ok)
        #expect(try await Self.run(["config", "set", "api-url", "http://api.dreadcast.app", "--plain"], environment: env).code == .usage)
        // RainViewer is gone, and so are its palette and the setting that chose it.
        let gone = try await Self.run(["config", "set", "radar-source", "rainviewer", "--plain"], environment: env)
        #expect(gone.code == .usage && gone.err.contains("radar-source is gone"))
        #expect(try await Self.run(["config", "set", "palette", "rainviewer", "--plain"], environment: env).code == .usage)
        let config = try Self.json(try await Self.run(["config", "--json"], environment: env).out)
        #expect(config["apiURL"] as? String == "https://api.dreadcast.app")
        #expect(config["radarSource"] == nil)
        let credits = try await Self.run(["credits", "--plain"], environment: env).out
        #expect(credits.contains("NOAA MRMS") && credits.contains("NOAA Enterprise Rain Rate"))
        #expect(credits.contains("EUMETNET OPERA") && credits.contains("creativecommons.org/licenses/by/4.0"))
        #expect(!credits.uppercased().contains("RAINVIEWER"))
    }
}
