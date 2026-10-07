import Foundation
import DreadcastKit
import DreadTerminal

/// `dread radar`: the animated loop, drawn as half-blocks or as an inline image.
enum RadarCommand {
    enum Renderer: String {
        case kitty, iterm2, halfblock
    }

    struct Layout {
        let columns: Int
        let rows: Int
        let pixelWidth: Int
        let pixelHeight: Int
    }

    static func run(_ ctx: Context) async throws -> ExitCode {
        let place = try await ctx.resolveLocation()
        if ctx.mode != .pretty { return try await summary(ctx, place: place) }

        var range = Double(ctx.arguments.integer("range") ?? ctx.config.radarRange)
        guard (5...500).contains(range) else { return ctx.fail("--range must be between 5 and 500 miles.", code: .usage) }
        let palette = try palette(ctx)
        let renderer = renderer(ctx)
        let frameCount = max(2, min(12, ctx.arguments.integer("frames") ?? 8))
        let minimumDBZ = ctx.arguments.double("min-dbz") ?? 15
        let still = ctx.arguments.has("still") || ctx.terminal.reduceMotion || !ctx.terminal.isInputTTY
        let once = ctx.arguments.has("once")
        let s = ctx.styler

        let columns = min(max(40, ctx.arguments.integer("width") ?? (ctx.terminal.columns - 2)), 160)
        let rows = max(8, min(ctx.terminal.rows - 6, Int((Double(columns) / 3).rounded())))
        let layout: Layout = renderer == .halfblock
            ? Layout(columns: columns, rows: rows, pixelWidth: columns, pixelHeight: rows * 2)
            : Layout(columns: columns, rows: rows, pixelWidth: columns * 8, pixelHeight: rows * 16)

        Console.write(s.paint("  Loading radar…", Theme.faint) + "\r")
        let showLightning = !ctx.arguments.has("no-lightning")
        let lightningFetch = showLightning ? await ctx.lightning(place) : nil

        var state = LoopState(range: range, frames: [], frameIndex: 0, paused: still)
        // Whose radar this is, whether it's late, and the newest frame, from the last load.
        var credit = "RainViewer", delayed = false, newest: String?
        var problem = "unknown error"
        func load(range: Double) async -> (RadarScene, Raster, [Raster], [Date]) {
            let viewport = RadarViewport(center: place.coordinate, rangeMiles: range, width: layout.pixelWidth, height: layout.pixelHeight)
            let scene = RadarScene(viewport: viewport, palette: palette, minimumDBZ: minimumDBZ, units: ctx.units,
                                   style: ctx.mapStyle, highlight: ctx.highlight)
            let base = scene.base()
            do {
                let loop = try await ctx.radarLoop(for: place, viewport: viewport, frames: frameCount)
                credit = loop.credit
                delayed = loop.delayed
                newest = loop.newestFrame
                return (scene, base, loop.fields.map { scene.compose(base: base, field: $0) }, loop.fields.map(\.time))
            } catch {
                problem = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (scene, base, [], [])
            }
        }

        var (scene, _, frames, loadedTimes) = await load(range: range)
        Console.write(TerminalControl.clearLine + "\r")
        guard !frames.isEmpty else {
            return ctx.fail("Radar is unavailable: \(problem). Try again in a minute.", code: .unavailable)
        }
        var frameTimes = loadedTimes
        state.frames = frames
        state.frameIndex = frames.count - 1

        let strikes = lightningFetch?.value?.current(at: ctx.now) ?? []
        let fmt = Formatter(units: ctx.units, timeZone: ctx.timeZone(for: place))
        let imageID = Int.random(in: 1000...99_999)

        func header() -> String {
            var parts = [s.paint("dread radar", ctx.highlight, bold: true), place.name,
                         "\(Int(ctx.units.distance(miles: state.range).rounded())) \(ctx.units.distanceUnit)",
                         palette.title]
            if let lightningFetch {
                parts.append(lightningFetch.value == nil ? s.paint("lightning unavailable", Theme.advisory) : "lightning on")
            }
            return "  " + parts.joined(separator: s.paint(" · ", Theme.faint))
        }

        func hud() -> [String] {
            let times = Array(frameTimes)
            let time = state.frameIndex < times.count ? fmt.time(times[state.frameIndex]) : "--"
            let dots = (0..<state.frames.count).map { $0 == state.frameIndex ? s.paint("●", ctx.highlight) : s.paint("●", Theme.faint) }.joined()
            let keys = still ? "" : s.paint(state.paused ? "  paused · space play · ←/→ step · +/− zoom · q quit" : "  space pause · ←/→ step · +/− zoom · q quit", Theme.faint)
            let ramp = [18.0, 24, 30, 36, 42, 48, 54, 60, 66].map { s.paint("█", RGB(hex: palette.rgb(dbz: $0))) }.joined()
            var legend = "  dBZ " + ramp + s.paint(" 18 → 65+", Theme.faint)
            if !strikes.isEmpty || lightningFetch?.value != nil {
                legend += "    Lightning " + LightningAgeBand.allCases.map { s.paint($0.label.replacingOccurrences(of: " min", with: ""), Theme.lightning[$0.rawValue]) }.joined(separator: " ") + s.paint(" min", Theme.faint)
            }
            let age = (delayed ? "radar delayed · " : "latest frame ") + Formatter.ago(times.last ?? ctx.now, now: Date())
            return [
                "  " + s.paint("◀ ", ctx.highlight) + time + " " + dots + s.paint(" ▶", ctx.highlight) + keys,
                legend,
                "  " + s.paint("\(credit) · Natural Earth · \(age)", Theme.faint)
            ]
        }

        func mapLines(_ raster: Raster) -> [String] {
            switch renderer {
            case .halfblock:
                return HalfBlockRenderer.render(raster, styler: s, overlays: scene.overlays(placeName: place.name, strikes: strikes, now: ctx.now))
                    .map { " " + $0 }
            case .kitty, .iterm2:
                return []
            }
        }

        func imagePayload(_ raster: Raster) -> String {
            var marked = raster
            scene.drawMarkers(on: &marked, strikes: strikes, now: ctx.now)
            guard let png = PNGEncoder.encode(marked) else { return "" }
            return renderer == .kitty
                ? KittyGraphics.display(png: png, id: imageID, columns: layout.columns, rows: layout.rows)
                : ITermImages.display(png: png, columns: layout.columns, rows: layout.rows)
        }

        // First draw.
        var output = header() + "\n"
        switch renderer {
        case .halfblock:
            output += mapLines(state.current).joined(separator: "\n") + "\n"
        case .kitty:
            output += " " + imagePayload(state.current) + String(repeating: "\n", count: layout.rows)
        case .iterm2:
            output += " " + imagePayload(state.current) + "\n"
        }
        output += hud().joined(separator: "\n") + "\n"
        Console.write(output)
        if still && !once { return .ok }

        let hudCount = 3
        let cleanup = (renderer == .kitty ? KittyGraphics.delete(id: imageID) : "") + "\n"
        // Raw mode owns the signal handlers so an interruption also restores echo.
        let raw = RawTerminal(alternateScreen: false, cleanup: cleanup)
        if raw == nil { InterruptGuard.install(cleanup: TerminalControl.showCursor + cleanup) }
        defer {
            raw?.restore()
            if raw == nil { InterruptGuard.clear() }
            Console.write(TerminalControl.showCursor)
        }

        func redraw(mapChanged: Bool) {
            var out = TerminalControl.moveUp(layout.rows + hudCount + 1) + "\r" + TerminalControl.clearLine + header() + "\n"
            switch renderer {
            case .halfblock:
                out += mapLines(state.current).map { "\r" + $0 }.joined(separator: "\n") + "\n"
            case .kitty:
                out += "\r " + (mapChanged ? imagePayload(state.current) : "") + "\u{1B}[\(layout.rows)B"
            case .iterm2:
                out += "\r " + imagePayload(state.current) + "\n"
            }
            out += hud().map { "\r" + TerminalControl.clearLine + $0 }.joined(separator: "\n") + "\n"
            Console.write(out)
        }

        var lastSwitch = Date()
        var advances = 0
        var lastManifestCheck = Date()
        if once {
            state.frameIndex = 0
            redraw(mapChanged: true)
        }
        while true {
            let delay = state.frameIndex == state.frames.count - 1 ? 1.7 : 0.65
            let key = raw?.readKey(timeout: 0.1) ?? { Thread.sleep(forTimeInterval: 0.1); return nil }()
            switch key {
            case .character("q"), .character("Q"), .escape, .interrupt:
                if renderer == .kitty { Console.write(KittyGraphics.delete(id: imageID)) }
                return .ok
            case .character(" "):
                state.paused.toggle()
                redraw(mapChanged: false)
            case .right:
                state.paused = true
                state.frameIndex = (state.frameIndex + 1) % state.frames.count
                redraw(mapChanged: true)
            case .left:
                state.paused = true
                state.frameIndex = (state.frameIndex - 1 + state.frames.count) % state.frames.count
                redraw(mapChanged: true)
            case .character("+"), .character("="), .character("-"), .character("_"):
                // + zooms in (smaller range), − zooms out.
                let ranges = Config.ranges.map(Double.init)
                let currentIndex = ranges.indices.min { abs(ranges[$0] - state.range) < abs(ranges[$1] - state.range) } ?? 1
                let zoomIn = key == .character("+") || key == .character("=")
                let next = ranges[zoomIn ? max(0, currentIndex - 1) : min(ranges.count - 1, currentIndex + 1)]
                guard next != state.range else { break }
                state.range = next
                range = next
                Console.write(TerminalControl.moveUp(hudCount) + "\r" + TerminalControl.clearLine + s.paint("  Loading \(Int(next)) mi…", Theme.faint) + "\n" + String(repeating: "\n", count: hudCount - 1))
                let reloaded = await load(range: next)
                scene = reloaded.0
                if !reloaded.2.isEmpty {
                    state.frames = reloaded.2
                    frameTimes = reloaded.3
                    state.frameIndex = state.frames.count - 1
                }
                redraw(mapChanged: true)
            default:
                break
            }

            if !state.paused, Date().timeIntervalSince(lastSwitch) >= delay {
                state.frameIndex = (state.frameIndex + 1) % state.frames.count
                advances += 1
                lastSwitch = Date()
                redraw(mapChanged: true)
                if once, advances >= state.frames.count - 1 { return .ok }
            }

            // New frames arrive every two minutes (MRMS) to ten (RainViewer).
            if Date().timeIntervalSince(lastManifestCheck) > 120 {
                lastManifestCheck = Date()
                ctx.refreshClock()
                if let fresh = await ctx.newestRadarFrame(for: place), fresh != newest {
                    let reloaded = await load(range: state.range)
                    if !reloaded.2.isEmpty {
                        scene = reloaded.0
                        state.frames = reloaded.2
                        frameTimes = reloaded.3
                        state.frameIndex = state.frames.count - 1
                        redraw(mapChanged: true)
                    }
                }
            }
        }
    }

    struct LoopState {
        var range: Double
        var frames: [Raster]
        var frameIndex: Int
        var paused: Bool
        var current: Raster { frames[min(frameIndex, frames.count - 1)] }
    }

    static func palette(_ ctx: Context) throws -> RadarPalette {
        guard let name = ctx.arguments.value("palette") else { return ctx.config.palette }
        guard let palette = RadarPalette(rawValue: name.lowercased()) else {
            throw DreadcastError.notFound("Unknown palette \(name). Choose dreadcast, classic, viridis or rainviewer.")
        }
        return palette
    }

    static func renderer(_ ctx: Context) -> Renderer {
        let requested = (ctx.arguments.value("renderer") ?? ctx.config.renderer).lowercased()
        switch requested {
        case "kitty": return .kitty
        case "iterm2", "iterm": return .iterm2
        case "halfblock", "half-blocks", "halfblocks", "256", "blocks": return .halfblock
        default:
            switch ctx.terminal.graphics {
            case .kitty: return .kitty
            case .iterm2: return .iterm2
            case .none: return .halfblock
            }
        }
    }

    /// Plain and JSON output: what the radar shows, in words.
    static func summary(_ ctx: Context, place: Place) async throws -> ExitCode {
        let nowcast = await ctx.nowcast(place)
        guard let n = nowcast.value else {
            return ctx.fail("Radar is unavailable: \(nowcast.error ?? "unknown error").", code: .unavailable)
        }
        let fmt = Formatter(units: ctx.units, timeZone: ctx.timeZone(for: place))
        if ctx.mode == .json {
            ctx.writeJSON(RadarJSON(place: place, nowcast: n, stale: nowcast.isStale))
            return .ok
        }
        var lines = ["Radar for \(place.name), latest frame \(n.latestFrame.map(fmt.time) ?? "unknown")."]
        if n.isRainingNow {
            lines.append("Rain is falling at your location (\(Int(n.currentDBZ ?? 0)) dBZ).")
        } else if let miles = n.nearestEchoMiles, let bearing = n.nearestEchoBearing {
            lines.append("Nearest rain: \(fmt.distance(miles: miles)) \(Compass.word(bearing)).")
        } else {
            lines.append("No rain within \(fmt.distance(miles: Context.nowcastRangeMiles)).")
        }
        if let mph = n.motionMPH, let bearing = n.motionBearing {
            lines.append("Echoes are moving \(Compass.word(bearing)) at \(fmt.speed(mph: mph)).")
        }
        lines.append("Source: \(n.source ?? "RainViewer").")
        ctx.write(lines)
        return .ok
    }
}

struct RadarJSON: Encodable {
    let schema = "dreadcast.radar/1"
    let location: LocationJSON
    let source = "rainviewer"
    let frames: [Date]
    let raining: Bool
    let currentDBZ: Double?
    let nearestEchoMiles: Double?
    let nearestEchoBearing: Double?
    let motionBearing: Double?
    let motionMPH: Double?
    let stormCells: [StormCellJSON]
    let stale: Bool

    init(place: Place, nowcast: Nowcast, stale: Bool) {
        location = LocationJSON(place)
        frames = nowcast.frameTimes
        raining = nowcast.isRainingNow
        currentDBZ = nowcast.currentDBZ
        nearestEchoMiles = nowcast.nearestEchoMiles.map { ($0 * 10).rounded() / 10 }
        nearestEchoBearing = nowcast.nearestEchoBearing.map { $0.rounded() }
        motionBearing = nowcast.motionBearing.map { $0.rounded() }
        motionMPH = nowcast.motionMPH.map { $0.rounded() }
        stormCells = nowcast.cells.map(StormCellJSON.init)
        self.stale = stale
    }
}

struct StormCellJSON: Encodable {
    let id: Int
    let latitude: Double
    let longitude: Double
    let distanceMiles: Double
    let bearing: Double
    let maxDBZ: Double
    let closestApproachMiles: Double?
    let closestApproachMinutes: Int?
    let arrivalMinutes: Int?

    init(_ cell: StormCell) {
        id = cell.id
        latitude = (cell.latitude * 100).rounded() / 100
        longitude = (cell.longitude * 100).rounded() / 100
        distanceMiles = (cell.distanceMiles * 10).rounded() / 10
        bearing = cell.bearing.rounded()
        maxDBZ = cell.maxDBZ
        closestApproachMiles = cell.closestApproachMiles.map { ($0 * 10).rounded() / 10 }
        closestApproachMinutes = cell.closestApproachMinutes
        arrivalMinutes = cell.arrivalMinutes
    }
}
