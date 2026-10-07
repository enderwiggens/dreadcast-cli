import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import DreadTerminal
@testable import DreadcastKit
@testable import DreadCLI

/// A manifest in the Dreadcast API's shape (dreadcast-server `docs/API.md`), for the
/// contiguous-US region at zooms 3–8. Every tile is `n` except those listed as stored.
enum RadarAPIFixture {
    static let bounds = DreadcastRadarManifest.contiguousUS
    static let tileHost = "tiles.dreadcast.app"

    static var levels: [(z: Int, x: [Int], y: [Int])] {
        DreadcastRadarManifest.zooms.map { z in
            let northwest = WebMercator.pixel(GeoCoordinate(latitude: bounds[3], longitude: bounds[0]), zoom: z, tileSize: 1)
            let southeast = WebMercator.pixel(GeoCoordinate(latitude: bounds[1], longitude: bounds[2]), zoom: z, tileSize: 1)
            return (z, [Int(northwest.x), Int(southeast.x)], [Int(northwest.y), Int(southeast.y)])
        }
    }

    /// Run-length tile states with `stored` tiles as `t` and the rest `n`.
    static func states(stored: Set<String>) -> String {
        var letters: [Character] = []
        for level in levels {
            for x in level.x[0]...level.x[1] {
                for y in level.y[0]...level.y[1] { letters.append(stored.contains("\(level.z)/\(x)/\(y)") ? "t" : "n") }
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

    static func frameID(_ date: Date) -> String { DreadcastRadarManifest.frameID(for: date) }

    static func json(newest: Date, frames count: Int = 3, stored: Set<String> = [], status: String = "live",
                     host: String = tileHost, scheme: String = "https", tamper: (inout [String: Any]) -> Void = { _ in }) -> Data {
        let times = (0..<count).map { newest.addingTimeInterval(Double($0 - count + 1) * 240) }
        let states = Self.states(stored: stored)
        var object: [String: Any] = [
            "status": status,
            "newest_observed_at": ISO8601DateFormatter().string(from: times.last!),
            "product": "MergedBaseReflectivityQC_00.50",
            "encoding": "mrms-rg8-v1",
            "tile_size": 512, "min_zoom": 3, "max_zoom": 8,
            "region": ["id": "conus", "bounds": bounds],
            "tile_grid": levels.map { ["z": $0.z, "x": $0.x, "y": $0.y] },
            "frames": times.map { time -> [String: Any] in
                let id = frameID(time)
                return ["id": id, "observed_at": ISO8601DateFormatter().string(from: time), "flag_observed_at": NSNull(),
                        "tile_url": "\(scheme)://\(host)/mrms/snapshots/\(id)/conus/{z}/{x}/{y}.png", "tile_states": states]
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

    static let now = ISODate.parse("2026-10-07T12:00:00Z")!
    static let tampa = SceneTests.tampa
}

@Suite("Dreadcast radar API")
struct DreadcastRadarTests {
    typealias F = RadarAPIFixture

    @Test func decodesTheContract() throws {
        let manifest = try DreadcastRadarManifest.decode(F.json(newest: F.now), now: F.now)
        #expect(manifest.frames.count == 3)
        #expect(manifest.frames.last?.observedAt == F.now)
        #expect(manifest.levels.map(\.z) == Array(3...8))
        #expect(manifest.radarFrames.last?.path == F.frameID(F.now))
        #expect(!manifest.isDelayed(at: F.now))
        #expect(manifest.isDelayed(at: F.now.addingTimeInterval(11 * 60)))
        #expect(manifest.isUsable(at: F.now.addingTimeInterval(2 * 3600)))
        #expect(!manifest.isUsable(at: F.now.addingTimeInterval(4 * 3600)))
        #expect(manifest.covers(F.tampa.coordinate))
        #expect(!manifest.covers(GeoCoordinate(latitude: 51.51, longitude: -0.13)))
        let delayed = try DreadcastRadarManifest.decode(F.json(newest: F.now, status: "delayed"), now: F.now)
        #expect(delayed.isDelayed(at: F.now))
    }

    /// The Mac app's rules: nothing in a manifest becomes a request until it checks out.
    @Test func rejectsManifestsThatDontCheckOut() {
        func rejects(_ data: Data, allowLoopback: Bool = false) -> Bool {
            (try? DreadcastRadarManifest.decode(data, now: F.now, allowLoopback: allowLoopback)) == nil
        }
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
        #expect(rejects(F.json(newest: F.now) { object in
            var frames = object["frames"] as! [[String: Any]]
            frames[0]["tile_states"] = "t1"
            object["frames"] = frames
        }))
        #expect(rejects(F.json(newest: F.now) { object in
            var frames = object["frames"] as! [[String: Any]]
            frames[0]["id"] = "mrms-20000101t000000"
            object["frames"] = frames
        }))
        #expect(rejects(F.json(newest: F.now) { object in
            object["frames"] = Array((object["frames"] as! [[String: Any]]).reversed())
        }))
        #expect(rejects(F.json(newest: F.now) { object in
            var grid = object["tile_grid"] as! [[String: Any]]
            grid.removeLast()
            object["tile_grid"] = grid
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
        let level = F.levels[3]
        let stored: Set<String> = ["\(level.z)/\(level.x[0] + 1)/\(level.y[0] + 2)", "\(level.z)/\(level.x[1])/\(level.y[1])"]
        let manifest = try DreadcastRadarManifest.decode(F.json(newest: F.now, stored: stored), now: F.now)
        let states = manifest.states(for: manifest.frames[0])
        for x in level.x[0]...level.x[1] {
            for y in level.y[0]...level.y[1] {
                let expected = stored.contains("\(level.z)/\(x)/\(y)") ? DreadcastRadarManifest.t : DreadcastRadarManifest.n
                #expect(manifest.state(states, z: level.z, x: x, y: y) == expected)
            }
        }
        #expect(manifest.state(states, z: level.z, x: level.x[1] + 1, y: level.y[0]) == DreadcastRadarManifest.m)
        #expect(manifest.state(states, z: 9, x: 0, y: 0) == DreadcastRadarManifest.m)
    }

    @Test func tilesHoldMeasurements() throws {
        let tile = UniversalBlueDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: F.red(dbz: 40), green: 3)))
        #expect(tile.dbz[0] == 40 && tile.snow[0])
        let rain = UniversalBlueDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: F.red(dbz: 52.5), green: 6)))
        #expect(rain.dbz[1000] == 53 && !rain.snow[1000])
        for red: UInt8 in [0, 1] {
            let none = UniversalBlueDecoder.decodeMRMSTile(try PNGDecoder.decode(F.tile(red: red, green: 0)))
            #expect(none.dbz.allSatisfy { $0 == ReflectivityField.none })
        }
    }

    @Test func placesInTheUSUseTheAPIWhenOneIsSet() throws {
        let tampa = F.tampa
        let london = Place(name: "London", coordinate: GeoCoordinate(latitude: 51.51, longitude: -0.13), countryCode: "GB", source: .search)
        let unset = try SceneTests.context()
        #expect(unset.dreadcastAPI == Dreadcast.apiBaseURL)
        #expect(unset.radarSource(for: tampa) == .rainviewer)
        let set = try SceneTests.context()
        set.config.apiURL = "https://api.dreadcast.app/"
        let api = try #require(URL(string: "https://api.dreadcast.app"))
        #expect(set.radarSource(for: tampa) == .dreadcast(api))
        #expect(set.radarSource(for: london) == .rainviewer)
        set.config.radarSource = "rainviewer"
        #expect(set.radarSource(for: tampa) == .rainviewer)
        set.config.radarSource = "auto"
        set.config.apiURL = "off"
        #expect(set.radarSource(for: tampa) == .rainviewer)
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
    @Test func radarComesFromTheAPIsTiles() async throws {
        typealias F = RadarAPIFixture
        let env = try await Self.home(location: "27.95,-82.46")
        var environment = env
        environment["DREADCAST_API_URL"] = "https://api.dreadcast.app"

        // Store only the tile under Tampa at the zoom a 35-mile view uses.
        let viewport = RadarViewport(center: F.tampa.coordinate, rangeMiles: 35, width: 80, height: 60)
        let zoom = RadarLoader().dreadcastZoom(for: viewport)
        let p = WebMercator.pixel(F.tampa.coordinate, zoom: zoom, tileSize: 1)
        let stored: Set<String> = ["\(zoom)/\(Int(p.x))/\(Int(p.y))"]
        let manifest = F.json(newest: Date(), stored: stored)
        StubProvider.reset(["api.dreadcast.app": (200, String(decoding: manifest, as: UTF8.self)),
                            F.tileHost: (200, "")])
        StubProvider.lock.withLock { StubProvider.tileBody = F.tile(red: F.red(dbz: 45), green: 6) }
        defer { StubProvider.lock.withLock { StubProvider.tileBody = nil } }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProvider.self]
        let terminal = TerminalInfo(isOutputTTY: false, isInputTTY: false, columns: 100, rows: 40, colorMode: .none,
                                    graphics: .none, program: nil, insideMultiplexer: false, reduceMotion: false)
        let ctx = Context(arguments: Arguments(command: "radar"), environment: environment, terminal: terminal,
                          http: HTTPClient(session: URLSession(configuration: configuration)))
        let loop = try await ctx.radarLoop(for: F.tampa, viewport: viewport, frames: 2)
        #expect(loop.credit == "NOAA MRMS")
        #expect(loop.fields.count == 2)
        let center = try #require(loop.fields.last?.value(x: 40, y: 30))
        #expect(center == 45)

        // Only stored tiles are requested; listed empty tiles never are.
        let tileRequests = StubProvider.seen.filter { $0.url?.host == F.tileHost }.compactMap { $0.url?.path }
        #expect(!tileRequests.isEmpty)
        #expect(tileRequests.allSatisfy { path in stored.contains { path.hasSuffix("/\($0).png") } })
        #expect(StubProvider.seen.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("dreadcast-cli/") == true })
    }

    @Test func radarFallsBackToRainViewerWhenTheAPIIsDown() async throws {
        var environment = try await Self.home(location: "27.95,-82.46")
        environment["DREADCAST_API_URL"] = "https://api.dreadcast.app"
        StubProvider.reset(["api.dreadcast.app": (503, #"{"error":{"code":"radar_unavailable"}}"#)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProvider.self]
        let terminal = TerminalInfo(isOutputTTY: false, isInputTTY: false, columns: 100, rows: 40, colorMode: .none,
                                    graphics: .none, program: nil, insideMultiplexer: false, reduceMotion: false)
        let ctx = Context(arguments: Arguments(command: "radar"), environment: environment, terminal: terminal,
                          http: HTTPClient(session: URLSession(configuration: configuration)))
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
    }
}
