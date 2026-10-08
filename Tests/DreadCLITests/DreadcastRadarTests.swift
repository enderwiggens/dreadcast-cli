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
                     tamper: (inout [String: Any]) -> Void = { _ in }) -> Data {
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
        let tile = UniversalBlueDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: F.red(dbz: 40), green: 3)))
        #expect(tile.dbz[0] == 40 && tile.snow[0])
        let rain = UniversalBlueDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: F.red(dbz: 52.5), green: 6)))
        #expect(rain.dbz[1000] == 53 && !rain.snow[1000])
        // Europe has no precipitation type: green is 255, never snow.
        let europe = UniversalBlueDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: F.red(dbz: 30), green: 255)))
        #expect(europe.dbz[0] == 30 && !europe.snow[0])
        let clear = UniversalBlueDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: 1, green: 0)))
        #expect(clear.dbz.allSatisfy { $0 == ReflectivityField.none } && clear.isFullyCovered)
        let uncovered = UniversalBlueDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: 0, green: 0)))
        #expect(uncovered.dbz.allSatisfy { $0 == UniversalBlueDecoder.uncovered } && !uncovered.isFullyCovered)
    }

    /// Where regions overlap, each pixel comes from the first region with coverage there.
    @Test func overlappingRegionsTakeTheFirstWithCoverage() {
        typealias Tile = UniversalBlueDecoder.Tile
        let first = Tile(size: 2, dbz: [30, UniversalBlueDecoder.uncovered, ReflectivityField.none, UniversalBlueDecoder.uncovered],
                         snow: [false, false, false, false])
        let second = Tile(size: 2, dbz: [50, 45, 50, UniversalBlueDecoder.uncovered], snow: [false, true, false, false])
        let drawn = first.filling(from: second)
        #expect(drawn.dbz == [30, 45, ReflectivityField.none, UniversalBlueDecoder.uncovered])
        #expect(drawn.snow == [false, true, false, false])
        #expect(!drawn.isFullyCovered)
    }

    @Test func theAPIIsUsedOnlyWhenSetAndNotOptedOut() throws {
        let unset = try SceneTests.context()
        #expect(unset.dreadcastAPI == Dreadcast.apiBaseURL)
        #expect(unset.radarAPI == Dreadcast.apiBaseURL)
        let set = try SceneTests.context()
        set.config.apiURL = "https://api.dreadcast.app/"
        #expect(set.radarAPI == URL(string: "https://api.dreadcast.app"))
        set.config.radarSource = "rainviewer"
        #expect(set.radarAPI == nil)
        set.config.radarSource = "auto"
        set.config.apiURL = "off"
        #expect(set.radarAPI == nil)
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
        #expect(loop.fromAPI && !loop.delayed)
        #expect(loop.fields.count == 2)
        let center = try #require(loop.fields.last?.value(x: 40, y: 30))
        #expect(center == 45)
        #expect(loop.newestFrame == F.id("mrms", newest))
        #expect(await ctx.newestRadarFrame(for: F.tampa, fromAPI: true) == loop.newestFrame)

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

    /// Inside a region's bounds but outside its radars, as in Italy for Europe: the
    /// place's own pixel has no coverage, so RainViewer draws it.
    @Test func placesWithoutCoverageUseRainViewer() async throws {
        typealias F = RadarAPIFixture
        let ctx = Self.radarContext(try await Self.home(location: "51.51,-0.13"))
        let viewport = RadarViewport(center: F.london.coordinate, rangeMiles: 35, width: 40, height: 30)
        Self.serveRadar(F.json(newest: Date(), missing: [F.tileKey(F.london, viewport: viewport)]), tile: nil)
        await #expect(throws: (any Error).self) { try await ctx.radarLoop(for: F.london, viewport: viewport, frames: 2) }
        let hosts = Set(StubProvider.seen.compactMap { $0.url?.host })
        #expect(hosts.contains("api.dreadcast.app"))
        #expect(!hosts.contains(F.tileHost))
        #expect(hosts.contains { $0.contains("rainviewer") })

        // And places outside every region never use the API's tiles.
        Self.serveRadar(F.json(newest: Date()), tile: nil)
        let tokyo = RadarViewport(center: F.tokyo.coordinate, rangeMiles: 35, width: 40, height: 30)
        await #expect(throws: (any Error).self) { try await ctx.radarLoop(for: F.tokyo, viewport: tokyo, frames: 2) }
        #expect(!StubProvider.seen.contains { $0.url?.host == F.tileHost })
    }

    @Test func radarFallsBackToRainViewerWhenTheAPIIsDown() async throws {
        let ctx = Self.radarContext(try await Self.home(location: "27.95,-82.46"))
        StubProvider.reset(["api.dreadcast.app": (503, #"{"error":{"code":"radar_unavailable"}}"#)])
        let viewport = RadarViewport(center: RadarAPIFixture.tampa.coordinate, rangeMiles: 35, width: 40, height: 30)
        await #expect(throws: (any Error).self) { try await ctx.radarLoop(for: RadarAPIFixture.tampa, viewport: viewport, frames: 2) }
        let hosts = Set(StubProvider.seen.compactMap { $0.url?.host })
        #expect(hosts.contains("api.dreadcast.app"))
        #expect(hosts.contains { $0.contains("rainviewer") })
    }

    @Test func radarSettingsValidate() async throws {
        let env = try await Self.home()
        #expect(try await Self.run(["config", "set", "api-url", "https://api.dreadcast.app/", "--plain"], environment: env).code == .ok)
        #expect(try await Self.run(["config", "set", "api-url", "http://api.dreadcast.app", "--plain"], environment: env).code == .usage)
        #expect(try await Self.run(["config", "set", "radar-source", "rainviewer", "--plain"], environment: env).code == .ok)
        #expect(try await Self.run(["config", "set", "radar-source", "nexrad", "--plain"], environment: env).code == .usage)
        let config = try Self.json(try await Self.run(["config", "--json"], environment: env).out)
        #expect(config["apiURL"] as? String == "https://api.dreadcast.app")
        #expect(config["radarSource"] as? String == "rainviewer")
        let credits = try await Self.run(["credits", "--plain"], environment: env).out
        #expect(credits.contains("NOAA MRMS"))
        #expect(credits.contains("EUMETNET OPERA") && credits.contains("creativecommons.org/licenses/by/4.0"))
    }
}
