import Foundation
import DreadcastKit
import DreadTerminal

/// `dread scene`: the app's free scenes as animated pixel art, with live conditions
/// beneath them. Scenes are decorative; the text holds the real readings.
enum SceneCommand {
    struct Readings {
        var place: Place?
        var weather: Fetched<WeatherReport>?
        var alerts: Fetched<[WeatherAlert]>?
    }

    static func run(_ ctx: Context) async throws -> ExitCode {
        var chosen: SceneID?
        if let name = ctx.arguments.positionals.first {
            switch SceneID.lookup(name) {
            case .scene(let scene): chosen = scene
            case .pro(let title):
                return ctx.fail("\(title) is a Pro scene in the Dreadcast app. Free scenes: \(SceneID.names).", code: .usage)
            case .unknown:
                return ctx.fail("Unknown scene \(name). Choose \(SceneID.names).", code: .usage)
            }
        }
        var fixedPeriod: ScenePeriod?
        if let time = ctx.arguments.value("time")?.lowercased(), time != "auto" {
            guard let period = ScenePeriod(rawValue: time) else {
                return ctx.fail("--time must be auto, dawn, day, dusk or night.", code: .usage)
            }
            fixedPeriod = period
        }

        // A location is optional: the scene still draws without one.
        var readings = Readings()
        do {
            readings.place = try await ctx.resolveLocation()
        } catch is Context.LocationError {
            readings.place = nil
        }
        if ctx.mode == .pretty, ctx.arguments.value("png") == nil { readings = await load(readings.place, ctx: ctx) }
        let zone = readings.weather?.value?.timeZone ?? readings.place.map(ctx.timeZone(for:)) ?? .current
        var scene = chosen ?? configuredScene(ctx, timeZone: zone)
        func period() -> ScenePeriod { fixedPeriod ?? ScenePeriod.at(ctx.now, timeZone: zone) }

        // Exporting a PNG works the same whether or not output goes to a terminal.
        if let path = ctx.arguments.value("png") {
            return export(scene: scene, period: period(), to: path, ctx: ctx)
        }
        switch ctx.mode {
        case .json:
            ctx.writeJSON(SceneJSON(scene: scene, period: period(), automaticTime: fixedPeriod == nil))
            return .ok
        case .plain:
            ctx.write("\(scene.title), \(period().rawValue). Scenes are decorative; run `dread` for conditions.")
            return .ok
        case .pretty:
            break
        }
        guard ctx.styler.mode >= .ansi256 else {
            ctx.write("\(scene.title), \(period().rawValue). Scenes need a terminal with 256 colors or more; run `dread` for conditions.")
            return .ok
        }

        let interactive = ctx.terminal.isInputTTY && ctx.terminal.isOutputTTY
        if ctx.arguments.has("still") || ctx.terminal.reduceMotion || !interactive {
            ctx.write(still(scene: scene, period: period(), readings: readings, ctx: ctx))
            return .ok
        }
        guard let raw = RawTerminal(alternateScreen: true) else {
            ctx.write(still(scene: scene, period: period(), readings: readings, ctx: ctx))
            return .ok
        }
        defer { raw.restore() }

        let s = ctx.styler
        var size = TerminalInfo.windowSize() ?? (ctx.terminal.columns, ctx.terminal.rows)
        var previous: HalfBlockFrame?
        var previousText: [String] = []
        var start = Date()
        var paused = false
        var frozen = 0.0
        var showText = true
        var lastClock = Date()
        var lastRefresh = Date()
        var frames = 0
        Console.write(TerminalControl.clearScreen)
        while true {
            if let current = TerminalInfo.windowSize(), current != size || raw.takeResumed() {
                size = current
                previous = nil
                previousText = []
                Console.write(Styler.reset + TerminalControl.clearScreen)
            }
            let columns = max(20, size.0)
            let now = period()
            // The art fills the window; the readings sit below it on the terminal's own background.
            var text: [String] = []
            if showText && size.1 >= 14 {
                text = [""] + SceneInfo.lines(scene: scene, period: now, readings: readings, ctx: ctx, width: columns)
            }
            text.append(hud(scene: scene, period: now, automatic: fixedPeriod == nil, paused: paused, columns: columns, styler: s))
            let artRows = max(4, size.1 - text.count)
            let elapsed = paused ? frozen : Date().timeIntervalSince(start)
            let raster = ScenePainter(scene: scene, period: now, time: elapsed, still: false, moon: LunarPhase(at: ctx.now))
                .paint(width: columns, height: artRows * 2)
            let frame = HalfBlockFrame(raster: raster)
            var out = frame.update(from: previous, styler: s, row: 1, column: 1)
            if text != previousText {
                for (i, line) in text.enumerated() {
                    out += TerminalControl.moveTo(row: artRows + 1 + i, column: 1) + TerminalControl.clearLine + line
                }
                previousText = text
            }
            Console.write(out)
            previous = frame
            frames += 1
            if ctx.arguments.has("once"), frames >= 40 { return .ok }

            // About nine frames a second, slower when frames are heavy, so a slow
            // connection never receives more than about 200 KB a second.
            switch raw.readKey(timeout: max(0.11, Double(out.utf8.count) / 200_000)) {
            case .character("q"), .character("Q"), .escape, .interrupt:
                return .ok
            case .right, .character("n"):
                scene = scene.adjacent(1)
            case .left, .character("p"):
                scene = scene.adjacent(-1)
            case .character("t"), .up, .down:
                // auto → dawn → day → dusk → night → auto
                if let current = fixedPeriod {
                    fixedPeriod = current == .night ? nil : current.next
                } else {
                    fixedPeriod = .dawn
                }
            case .character("i"):
                showText.toggle()
                previous = nil
                previousText = []
                Console.write(Styler.reset + TerminalControl.clearScreen)
            case .character(" "):
                if paused {
                    start = Date().addingTimeInterval(-frozen)
                } else {
                    frozen = elapsed
                }
                paused.toggle()
            default:
                break
            }

            if Date().timeIntervalSince(lastClock) >= 30 {
                ctx.refreshClock()
                lastClock = Date()
            }
            if Date().timeIntervalSince(lastRefresh) >= 600, readings.place != nil {
                lastRefresh = Date()
                readings = await load(readings.place, ctx: ctx)
            }
        }
    }

    static func load(_ place: Place?, ctx: Context) async -> Readings {
        guard let place else { return Readings() }
        async let weather = ctx.weather(place)
        async let alerts = ctx.alerts(place)
        let (w, a) = await (weather, alerts)
        return Readings(place: place, weather: w, alerts: place.isUnitedStates ? a : nil)
    }

    /// The configured scene: a name, or `daily` for a different one each day. Asteroid
    /// Watch unless set otherwise.
    static func configuredScene(_ ctx: Context, timeZone: TimeZone) -> SceneID {
        let value = ctx.config.scene.lowercased()
        if value == "daily" { return .daily(on: ctx.now, timeZone: timeZone) }
        if case .scene(let scene) = SceneID.lookup(value) { return scene }
        return .asteroid
    }

    static func hud(scene: SceneID, period: ScenePeriod, automatic: Bool, paused: Bool, columns: Int, styler s: Styler) -> String {
        let state = "\(period.title)\(automatic ? " (auto)" : "")\(paused ? " · paused" : "")"
        let keys = columns >= 96
            ? "←/→ scene · t time of day · i readings · space pause · q quit"
            : "←/→ scene · t time · q quit"
        let left = "  " + s.paint("◀ ", scene.accent) + s.paint(scene.title, Theme.porcelain) + s.paint(" ▶", scene.accent)
            + s.paint("  " + state, Theme.faint)
        return TextWidth.spread(left, s.paint(keys, Theme.faint), width: columns - 2)
    }

    /// A composed still frame, inline: a 3:1 panorama with the readings below it.
    static func still(scene: SceneID, period: ScenePeriod, readings: Readings, ctx: Context) -> [String] {
        let width = min(max(40, ctx.terminal.columns - 4), 132)
        let rows = max(8, Int((Double(width) / 6).rounded()))
        let raster = ScenePainter(scene: scene, period: period, time: 0, still: true, moon: LunarPhase(at: ctx.now), layout: .panorama)
            .paint(width: width, height: rows * 2)
        var lines = [""] + HalfBlockFrame(raster: raster).lines(styler: ctx.styler).map { "  " + $0 }
        lines.append("")
        lines.append(contentsOf: SceneInfo.lines(scene: scene, period: period, readings: readings, ctx: ctx, width: width + 2))
        lines.append("")
        return lines
    }

    static func export(scene: SceneID, period: ScenePeriod, to path: String, ctx: Context) -> ExitCode {
        var columns = 120, rows = 40
        if let size = ctx.arguments.value("size") {
            let parts = size.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, (20...400).contains(parts[0]), (5...200).contains(parts[1]) else {
                return ctx.fail("--size must look like 120x40 (columns x rows).", code: .usage)
            }
            columns = parts[0]
            rows = parts[1]
        }
        var layout = SceneLayout.window
        if let name = ctx.arguments.value("layout") {
            guard let chosen = SceneLayout(rawValue: name.lowercased()) else {
                return ctx.fail("--layout must be window, panorama or strip.", code: .usage)
            }
            layout = chosen
        }
        let at = ctx.arguments.double("at")
        let raster = ScenePainter(scene: scene, period: period, time: at ?? 0, still: at == nil, moon: LunarPhase(at: ctx.now),
                                  layout: layout)
            .paint(width: columns, height: rows * 2)
        // Each pixel becomes an 8×8 block, so the file looks like the terminal.
        let scale = 8
        var large = Raster(width: raster.width * scale, height: raster.height * scale)
        for y in 0..<large.height {
            for x in 0..<large.width { large[x, y] = raster[x / scale, y / scale] }
        }
        guard let data = PNGEncoder.encode(large) else { return ctx.fail("Could not encode the image.", code: .unavailable) }
        do {
            try data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath), options: .atomic)
        } catch {
            return ctx.fail("Could not save \(path): \(error.localizedDescription)", code: .unavailable)
        }
        if ctx.mode == .json {
            struct Saved: Encodable { let schema = "dreadcast.scene/1"; let scene: String; let period: String; let saved: String }
            ctx.writeJSON(Saved(scene: scene.rawValue, period: period.rawValue, saved: path))
        } else {
            ctx.write("  Saved \(scene.title) · \(period.title) to \(path).")
        }
        return .ok
    }
}

struct SceneJSON: Encodable {
    let schema = "dreadcast.scene/1"
    let scene: String
    let title: String
    let period: String
    let automaticTime: Bool
    let scenes: [String]

    init(scene: SceneID, period: ScenePeriod, automaticTime: Bool) {
        self.scene = scene.rawValue
        title = scene.title
        self.period = period.rawValue
        self.automaticTime = automaticTime
        scenes = SceneID.allCases.map(\.rawValue)
    }
}
