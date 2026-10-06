import Foundation
import DreadcastKit
import DreadTerminal

/// `dread top`: a full-screen dashboard. Weather systems are listed like processes,
/// sorted by threat. Each source refreshes on its own cadence and fails independently.
enum TopCommand {
    /// Everything the dashboard shows. Copied out under the lock for each render.
    struct Snapshot: Sendable {
        var weather: Fetched<WeatherReport>?
        var alerts: Fetched<[WeatherAlert]>?
        var lightning: Fetched<LightningSnapshot>?
        var nowcast: Fetched<Nowcast>?
        var severe: Fetched<Context.SevereRisk>?
        var tropical: Fetched<[TropicalStorm]>?
        var fires: Fetched<[Wildfire]>?
        var air: Fetched<AirQualityReading>?
        var hazards: Fetched<HazardSummary>?
        var quakes: Fetched<EarthquakeSnapshot>?
        var lightningConfigured = false
        var lastFetch: [String: Date] = [:]
        var inFlight: Set<String> = []
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Snapshot()

        func with<T>(_ body: (inout Snapshot) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&data)
        }

        var snapshot: Snapshot { with { $0 } }
    }

    struct Row {
        let pid: Int
        let system: String
        let state: String
        let distance: String
        let bearing: String
        let moving: String
        let eta: String
        let peak: String
        let color: RGB?
        let stateColor: RGB?
        let detail: [String]
        let priority: Int
    }

    static let cadences: [(String, TimeInterval)] = [
        ("weather", 600), ("alerts", 120), ("lightning", 60), ("nowcast", 300), ("severe", 900),
        ("tropical", 900), ("fires", 300), ("air", 1800), ("hazards", 900), ("quakes", 300)
    ]

    static func run(_ ctx: Context) async throws -> ExitCode {
        let place = try await ctx.resolveLocation()
        guard ctx.mode == .pretty, ctx.terminal.isInputTTY, ctx.terminal.isOutputTTY else {
            return ctx.fail("dread top needs an interactive terminal. Try `dread --json` or `dread alerts --json`.", code: .usage)
        }
        guard let raw = RawTerminal(alternateScreen: true) else {
            return ctx.fail("Couldn’t take over the terminal.", code: .unavailable)
        }
        defer { raw.restore() }

        let state = State()
        let configured = Credentials.xweather(environment: ctx.environment) != nil
        state.with { $0.lightningConfigured = configured }
        var selected = 0
        var lastRender = Date.distantPast
        var strip = Strip(started: Date())
        while true {
            ctx.refreshClock()
            schedule(ctx: ctx, place: place, state: state)
            if Date().timeIntervalSince(lastRender) >= 1 {
                selected = render(ctx: ctx, place: place, state: state, selected: selected, strip: &strip)
                lastRender = Date()
            }
            guard let key = raw.readKey(timeout: 0.2) else { continue }
            switch key {
            case .character("q"), .character("Q"), .escape, .interrupt:
                return .ok
            case .up, .character("k"):
                selected = max(0, selected - 1)
                lastRender = .distantPast
            case .down, .character("j"):
                selected += 1
                lastRender = .distantPast
            case .character("r"), .character("R"):
                state.with { $0.lastFetch = [:] }
                ctx.cache.remove(key: "alerts-\(Context.placeKey(place))")
                lastRender = .distantPast
            case .character("s"), .character("S"):
                strip.hidden.toggle()
                lastRender = .distantPast
            default:
                break
            }
        }
    }

    static func schedule(ctx: Context, place: Place, state: State) {
        let now = Date()
        for (name, cadence) in cadences {
            let due = state.with { s -> Bool in
                guard !s.inFlight.contains(name) else { return false }
                if name == "lightning" && !s.lightningConfigured { return false }
                guard now.timeIntervalSince(s.lastFetch[name] ?? .distantPast) >= cadence else { return false }
                s.inFlight.insert(name)
                return true
            }
            guard due else { continue }
            Task.detached {
                switch name {
                case "weather": let v = await ctx.weather(place); state.with { $0.weather = v }
                case "alerts": let v = await ctx.alerts(place); state.with { $0.alerts = v }
                case "lightning": let v = await ctx.lightning(place); state.with { $0.lightning = v }
                case "nowcast": let v = await ctx.nowcast(place); state.with { $0.nowcast = v }
                case "severe": let v = await ctx.severeRisk(place); state.with { $0.severe = v }
                case "tropical": let v = await ctx.tropical(); state.with { $0.tropical = v }
                case "fires": let v = await ctx.wildfires(place); state.with { $0.fires = v }
                case "air": let v = await ctx.airQuality(place); state.with { $0.air = v }
                case "hazards": let v = await ctx.hazards(place); state.with { $0.hazards = v }
                case "quakes": let v = await ctx.earthquakes(); state.with { $0.quakes = v }
                default: break
                }
                state.with { $0.inFlight.remove(name); $0.lastFetch[name] = Date() }
            }
        }
    }

    // MARK: Rendering

    /// Today's scene as a strip over the dashboard: only in tall terminals, never while an
    /// alert is active or unknown, stepping every four seconds. `s` hides it.
    struct Strip {
        let started: Date
        var hidden = false
        var shown: [String] = []
        static let rows = 8
        static let minimumHeight = 40
    }

    static func stripLines(ctx: Context, place: Place, snapshot: Snapshot, zone: TimeZone, width: Int, height: Int, strip: Strip) -> [String] {
        guard !strip.hidden, height >= Strip.minimumHeight, ctx.styler.mode >= .ansi256, !ctx.arguments.has("no-scene") else { return [] }
        if place.isUnitedStates, snapshot.alerts?.value?.isEmpty != true { return [] }
        guard let scene = SceneCommand.configuredScene(ctx, timeZone: zone) else { return [] }
        let still = ctx.terminal.reduceMotion
        let time = still ? 0 : (Date().timeIntervalSince(strip.started) / 4).rounded(.down) * 4
        let raster = ScenePainter(scene: scene, period: ScenePeriod.at(ctx.now, timeZone: zone), time: time, still: still,
                                  moon: LunarPhase(at: ctx.now), layout: .strip)
            .paint(width: width - 2, height: Strip.rows * 2)
        return HalfBlockFrame(raster: raster).lines(styler: ctx.styler).map { " " + $0 } + [""]
    }

    static func render(ctx: Context, place: Place, state: State, selected requested: Int, strip: inout Strip) -> Int {
        let s = ctx.styler
        let size = TerminalInfo.windowSize() ?? (ctx.terminal.columns, ctx.terminal.rows)
        let width = max(60, size.0)
        let snapshot = state.snapshot
        let zone = snapshot.weather?.value?.timeZone ?? ctx.timeZone(for: place)
        let fmt = Formatter(units: ctx.units, timeZone: zone)
        let art = stripLines(ctx: ctx, place: place, snapshot: snapshot, zone: zone, width: width, height: max(16, size.1), strip: strip)
        let height = max(16, size.1) - art.count
        var lines: [String] = []

        let clock = Date()
        lines.append(TextWidth.spread(" " + s.paint("dread top", Theme.lamp, bold: true) + s.paint("  —  ", Theme.faint) + place.name
                                      + s.paint("  \(place.coordinate.formatted)", Theme.faint),
                                      s.paint(fmt.time(clock).replacingOccurrences(of: " ", with: ":\(String(format: "%02d", Calendar.current.component(.second, from: clock))) ") + " " + fmt.zoneAbbreviation(clock), Theme.faint) + " ", width: width))
        lines.append("")
        lines.append(contentsOf: meters(snapshot: snapshot, fmt: fmt, ctx: ctx, width: width))
        lines.append("")

        let rows = buildRows(snapshot: snapshot, place: place, fmt: fmt, ctx: ctx)
        let selected = min(max(0, requested), max(0, rows.count - 1))
        let header = " " + "PID".padding(6) + "SYSTEM".padding(28) + "STATE".padding(11) + "DIST".padding(9) + "BRG".padding(5) + "MOVING".padding(9) + "ETA".padding(13) + "PEAK"
        lines.append(s.paint(TextWidth.pad(header, to: width), TextStyle(foreground: Theme.mist, background: RGB(hex: 0x182B40), bold: true)))
        let detailHeight = 4
        let available = max(3, height - lines.count - detailHeight - 2)
        let start = max(0, min(selected - available + 1, rows.count - available))
        for (index, row) in rows.enumerated().dropFirst(start).prefix(available) {
            var text = " " + String(row.pid).padding(6) + row.system.cell(28)
            let stateText = row.state.cell(11)
            let rest = row.distance.cell(9) + row.bearing.cell(5) + row.moving.cell(9) + row.eta.cell(13) + row.peak
            if index == selected {
                text += stateText + rest
                lines.append(s.paint(TextWidth.pad(TextWidth.truncate(text, to: width), to: width), TextStyle(foreground: Theme.porcelain, background: RGB(hex: 0x1C3350), bold: true)))
            } else {
                let color = row.color ?? Theme.porcelain
                lines.append(s.paint(text, color) + s.paint(stateText, row.stateColor ?? color) + s.paint(rest, row.color ?? Theme.mist))
            }
        }
        while lines.count < height - detailHeight - 1 { lines.append("") }

        let detail = rows.isEmpty ? ["Waiting for data…"] : rows[selected].detail
        let title = rows.isEmpty ? "" : " \(rows[selected].pid) \(rows[selected].system) "
        lines.append(s.paint("──" + title + String(repeating: "─", count: max(0, width - TextWidth.of(title) - 3)), Theme.faint))
        for line in detail.flatMap({ TextWidth.wrap($0, width: width - 4) }).prefix(detailHeight - 1) {
            lines.append("  " + line)
        }
        while lines.count < height - 1 { lines.append("") }
        var keys: [(String, String)] = [("↑/↓", "select"), ("r", "refresh")]
        if max(16, size.1) >= Strip.minimumHeight, ctx.styler.mode >= .ansi256 { keys.append(("s", strip.hidden ? "show scene" : "hide scene")) }
        keys.append(("q", "quit"))
        let busy = snapshot.inFlight.isEmpty ? "" : "updating \(snapshot.inFlight.sorted().joined(separator: ", "))…"
        lines.append(TextWidth.spread(" " + keys.map { s.paint($0.0, Theme.lamp) + " " + s.paint($0.1, Theme.mist) }.joined(separator: "   "),
                                      s.paint(busy, Theme.faint) + " ", width: width))

        // The strip's rows are rewritten only when the picture changes.
        var output = ""
        if art != strip.shown {
            output += TerminalControl.home + art.map { $0 + "\u{1B}[K" }.joined(separator: "\r\n") + (art.isEmpty ? "" : "\r\n")
            strip.shown = art
        } else {
            output += TerminalControl.moveTo(row: art.count + 1, column: 1)
        }
        output += lines.prefix(height).map { TextWidth.truncateStyled($0, to: width) + "\u{1B}[K" }.joined(separator: "\r\n") + TerminalControl.clearToEnd
        Console.write(output)
        return selected
    }

    static func meters(snapshot: Snapshot, fmt: Formatter, ctx: Context, width: Int) -> [String] {
        let s = ctx.styler
        let report = snapshot.weather?.value
        let barWidth = 22
        func meter(_ label: String, _ fraction: Double, _ color: RGB, _ value: String) -> String {
            " " + s.paint(label.padding(10), Theme.mist) + s.paint("[", Theme.faint)
                + s.paint(Charts.bar(fraction, width: barWidth).padding(barWidth), color) + s.paint("]", Theme.faint) + " " + value.padding(13)
        }
        let strikes = snapshot.lightning?.value?.current(at: ctx.now).count
        let rainDBZ = snapshot.nowcast?.value?.currentDBZ ?? 0
        let rate = ctx.units == .imperial ? RainRate.inchesPerHour(dbz: rainDBZ) : RainRate.millimetersPerHour(dbz: rainDBZ)
        let rateText = ctx.units == .imperial ? String(format: "%.2f in/h", rate) : String(format: "%.1f mm/h", rate)
        let cape = report?.cape(at: ctx.now)

        let left = [
            meter("Lightning", Double(strikes ?? 0) / 60, Theme.lightning[0], strikes.map { "\($0)/20m" } ?? (snapshot.lightningConfigured ? "--" : "not set up")),
            meter("Rain rate", min(1, rate / (ctx.units == .imperial ? 2 : 50)), Theme.rain, snapshot.nowcast?.value == nil ? "--" : rateText),
            meter("CAPE", (cape ?? 0) / 4000, Theme.lightning[1], cape.map { fmt.grouped(Int($0)) + " J/kg" } ?? "--")
        ]
        var right: [String] = []
        if let report {
            let tendency = report.pressureTendency(at: ctx.now)
            let arrow = tendency.map { $0 <= -1 ? s.paint(String(format: "↓ %.1f/3h", abs($0)), Theme.warning) : $0 >= 1 ? s.paint(String(format: "↑ %.1f/3h", $0), Theme.mint) : s.paint("steady", Theme.mist) } ?? ""
            right.append(s.paint("Pressure  ", Theme.mist) + (report.current.pressure.map { String(format: "%.1f hPa ", $0) } ?? "-- ") + arrow)
            let dewPoints = report.hourly.filter { $0.time >= ctx.now.addingTimeInterval(-6 * 3600) && $0.time <= ctx.now.addingTimeInterval(6 * 3600) }.compactMap(\.dewPoint)
            let spark = dewPoints.isEmpty ? "" : s.paint(Charts.sparkline(dewPoints.map(Optional.init), minimum: (dewPoints.min() ?? 0) - 1, maximum: (dewPoints.max() ?? 1) + 1), Theme.mint)
            right.append(s.paint("Dew point ", Theme.mist) + fmt.temperature(report.current.dewPoint, unit: true) + " " + spark)
            right.append(s.paint("Wind      ", Theme.mist) + fmt.wind(speed: report.current.windSpeed, gust: report.current.windGusts, direction: report.current.windDirection))
        } else {
            right = [s.paint("Conditions loading…", Theme.faint), "", ""]
        }
        return zip(left, right).map { $0 + "  " + $1 }
    }

    static func buildRows(snapshot: Snapshot, place: Place, fmt: Formatter, ctx: Context) -> [Row] {
        var rows: [Row] = []
        let here = place.coordinate
        func unavailable(_ pid: Int, _ system: String, _ fetched: (any FetchedError)?, priority: Int) {
            rows.append(Row(pid: pid, system: system, state: "UNAVAILABLE", distance: "—", bearing: "—", moving: "—", eta: "—", peak: "—",
                            color: Theme.faint, stateColor: Theme.advisory, detail: [fetched?.message ?? "Not loaded yet."], priority: priority))
        }

        // Alerts first: hazard, area, time and the official instruction.
        if let alerts = snapshot.alerts {
            if let list = alerts.value {
                for (i, alert) in list.enumerated() {
                    let color = NowCommand.alertColor(alert)
                    rows.append(Row(pid: 9001 + i, system: "▲ " + alert.event, state: "ACTIVE", distance: "here", bearing: "—", moving: "—",
                                    eta: alert.endsOrExpires.map { "til " + fmt.time($0) } ?? "—", peak: alert.severity.rawValue,
                                    color: color, stateColor: color,
                                    detail: [alert.headline, alert.instruction.flatMap(NowCommand.firstSentence) ?? "", "Area: \(alert.areaDescription)"].filter { !$0.isEmpty },
                                    priority: 1000 + alert.level.hashRank * 100 + alert.severity.hashRank))
                }
            } else if place.isUnitedStates {
                unavailable(9000, "NWS alerts", alerts, priority: 900)
            }
        }

        // Radar: rain timing and strong cells.
        if let nowcast = snapshot.nowcast {
            if let n = nowcast.value {
                let moving = n.motionBearing.map { Compass.octant($0) + " " + String(Int((n.motionMPH ?? 0).rounded())) } ?? "—"
                if n.isRainingNow {
                    rows.append(Row(pid: 8800, system: "Rain overhead", state: RainRate.Intensity(dbz: n.currentDBZ ?? 0).label.uppercased(), distance: "here", bearing: "—",
                                    moving: moving, eta: n.endMinutes.map { "ends ~\($0)m" } ?? "2 h+", peak: n.peakDBZ.map { "\(Int($0)) dBZ" } ?? "—",
                                    color: Theme.rain, stateColor: Theme.rain, detail: [EtaCommand.headline(n, fmt: fmt, ctx: ctx, styled: false)], priority: 700))
                } else if let arrival = n.arrivalMinutes {
                    rows.append(Row(pid: 8800, system: "Rain approaching", state: "MOVING",
                                    distance: n.nearestEchoMiles.map { fmt.distance(miles: $0) } ?? "—", bearing: n.nearestEchoBearing.map { Compass.point($0) } ?? "—",
                                    moving: moving, eta: "\(arrival) min", peak: n.peakDBZ.map { "\(Int($0)) dBZ" } ?? "—",
                                    color: nil, stateColor: Theme.lightning[1], detail: [EtaCommand.headline(n, fmt: fmt, ctx: ctx, styled: false), "Confidence: \(n.confidence.rawValue)."], priority: 600 - arrival))
                } else {
                    rows.append(Row(pid: 8800, system: n.nearestEchoMiles == nil ? "No rain nearby" : "Nearest rain", state: n.nearestEchoMiles == nil ? "CLEAR" : "DISTANT",
                                    distance: n.nearestEchoMiles.map { fmt.distance(miles: $0) } ?? "—", bearing: n.nearestEchoBearing.map { Compass.point($0) } ?? "—",
                                    moving: moving, eta: "—", peak: "—", color: Theme.mist, stateColor: Theme.mint,
                                    detail: [EtaCommand.headline(n, fmt: fmt, ctx: ctx, styled: false)],
                                    priority: n.nearestEchoMiles.map { $0 < 50 ? 400 - Int($0 * 2) : 100 } ?? 100))
                }
                for (i, cell) in n.cells.prefix(4).enumerated() {
                    let eta = cell.arrivalMinutes.map { "\($0) min" } ?? cell.closestApproachMinutes.map { "passes \($0)m" } ?? "—"
                    var detail = "Strongest echo \(Int(cell.maxDBZ)) dBZ, about \(Int(cell.areaSquareMiles.rounded())) sq mi of heavy rain."
                    if let miss = cell.closestApproachMiles, let minutes = cell.closestApproachMinutes {
                        detail += " Closest approach \(fmt.distance(miles: miss)) in about \(minutes) min."
                    }
                    rows.append(Row(pid: 8801 + i, system: "Storm cell C\(cell.id)", state: n.trend == .intensifying ? "GROWING" : n.trend == .weakening ? "WEAKENING" : "STEADY",
                                    distance: fmt.distance(miles: cell.distanceMiles), bearing: Compass.point(cell.bearing), moving: moving, eta: eta,
                                    peak: "\(Int(cell.maxDBZ)) dBZ", color: nil, stateColor: Theme.lightning[cell.maxDBZ >= 50 ? 2 : 1],
                                    detail: [detail, "Radar frames end \(n.latestFrame.map(fmt.time) ?? "--"). Motion is shared by all echoes."],
                                    priority: 500 + (cell.arrivalMinutes.map { 120 - min(120, $0) } ?? 0) - Int(cell.distanceMiles)))
                }
            } else {
                unavailable(8800, "Radar", nowcast, priority: 300)
            }
        }

        if snapshot.lightningConfigured, let lightning = snapshot.lightning {
            if let snap = lightning.value {
                let strikes = snap.current(at: ctx.now)
                let nearest = snap.nearest(at: ctx.now)
                rows.append(Row(pid: 8790, system: "Lightning", state: strikes.isEmpty ? "QUIET" : "ACTIVE",
                                distance: nearest.map { fmt.distance(miles: $0.miles) } ?? "—",
                                bearing: nearest.map { Compass.point(snap.center.bearingDegrees(to: $0.strike.coordinate)) } ?? "—",
                                moving: "—", eta: "—", peak: "\(strikes.count) in 20 min", color: nil, stateColor: strikes.isEmpty ? Theme.mint : Theme.lightning[0],
                                detail: ["\(strikes.count) strikes within \(fmt.distance(miles: snap.radiusMiles)) in the last 20 minutes (Xweather)."],
                                priority: strikes.isEmpty ? 50 : 650 - Int(nearest?.miles ?? 60)))
            } else {
                unavailable(8790, "Lightning", lightning, priority: 200)
            }
        }

        if let severe = snapshot.severe, place.isUnitedStates {
            if let risk = severe.value {
                rows.append(Row(pid: 5120, system: "SPC Day 1 outlook", state: risk.risk == .thunder ? "T-STORMS" : risk.risk.label.uppercased(), distance: "area", bearing: "—", moving: "—",
                                eta: risk.expires.map { "til " + fmt.time($0) } ?? "—", peak: risk.risk.level.map { "level \($0) of 5" } ?? "—",
                                color: risk.risk >= .slight ? nil : Theme.mist, stateColor: risk.risk >= .slight ? Theme.advisory : Theme.mist,
                                detail: ["Storm Prediction Center categorical risk for today at this location: \(risk.risk.label.lowercased())."],
                                priority: risk.risk >= .slight ? 400 + risk.risk.rawValue : 20))
            } else {
                unavailable(5120, "SPC outlook", severe, priority: 10)
            }
        }

        if let storms = snapshot.tropical?.value {
            for (i, storm) in storms.enumerated() where storm.coordinate.distanceMiles(to: here) <= 1500 {
                let miles = storm.coordinate.distanceMiles(to: here)
                rows.append(Row(pid: 7001 + i, system: storm.classification.capitalized + " " + storm.name, state: "TRACKING",
                                distance: fmt.distance(miles: miles), bearing: Compass.point(here.bearingDegrees(to: storm.coordinate)), moving: "—", eta: "—",
                                peak: storm.maximumWindKnots.map { "\($0) kt" } ?? "—", color: Theme.mint, stateColor: Theme.mint,
                                detail: ["NHC advisory \(storm.advisory ?? ""). Follow the NHC and local officials for forecasts."],
                                priority: 300 + Int(max(0, 1500 - miles) / 10)))
            }
        }

        if let fires = snapshot.fires?.value {
            for (i, fire) in fires.prefix(3).enumerated() {
                let miles = fire.coordinate.distanceMiles(to: here)
                rows.append(Row(pid: 6001 + i, system: "Fire: " + fire.name, state: fire.percentContained.map { "\($0)% CONT" } ?? "ACTIVE",
                                distance: fmt.distance(miles: miles), bearing: Compass.point(here.bearingDegrees(to: fire.coordinate)), moving: "—", eta: "—",
                                peak: fire.acres.flatMap { $0 >= 1 ? fmt.grouped(Int($0)) + " ac" : nil } ?? "—", color: RGB(hex: 0xFFB66D), stateColor: RGB(hex: 0xFFB66D),
                                detail: ["NIFC incident \(fire.name)\(fire.state.map { ", \($0)" } ?? ""). Discovered \(fire.discoveredAt.map { fmt.day($0) } ?? "date unknown")."],
                                priority: 120 + Int(max(0, 100 - miles))))
            }
        }

        if let air = snapshot.air?.value {
            rows.append(Row(pid: 4401, system: "Air quality", state: air.category.uppercased().prefix(10).description, distance: "here", bearing: "—", moving: "—", eta: "—",
                            peak: "AQI \(air.usAQI)", color: Theme.mist, stateColor: air.usAQI > 100 ? Theme.warning : air.usAQI > 50 ? Theme.advisory : Theme.mint,
                            detail: ["US AQI \(air.usAQI) (\(air.category.lowercased())), modeled by CAMS via Open-Meteo."], priority: air.usAQI > 100 ? 350 : 15))
        }
        if let hazards = snapshot.hazards?.value {
            if let smoke = hazards.smokeAtLocation {
                rows.append(Row(pid: 4402, system: "Smoke (NOAA HMS)", state: smoke.uppercased(), distance: smoke == "none" ? "—" : "aloft", bearing: "—", moving: "—", eta: "—",
                                peak: "not at surface", color: Theme.faint, stateColor: smoke == "none" ? Theme.faint : Theme.advisory,
                                detail: ["Satellite-analyzed smoke over your location. This is not a surface air-quality measurement."], priority: smoke == "none" ? 5 : 150))
            }
            if let dust = hazards.dust {
                rows.append(Row(pid: 4403, system: "Dust (CAMS)", state: dust > 100 ? "ELEVATED" : "LOW", distance: "area", bearing: "—", moving: "—", eta: "—",
                                peak: String(format: "%.0f µg/m³", dust), color: Theme.faint, stateColor: dust > 100 ? Theme.advisory : Theme.faint,
                                detail: ["Modeled dust concentration near the surface."], priority: dust > 100 ? 140 : 4))
            }
            if let volcano = hazards.elevatedVolcanoes?.first, let miles = volcano.distanceMiles, miles < 1500 {
                rows.append(Row(pid: 4404, system: "Volcano: " + volcano.title, state: volcano.level.uppercased(), distance: fmt.distance(miles: miles), bearing: "—",
                                moving: "—", eta: "—", peak: volcano.detail ?? "—", color: Theme.mist, stateColor: Theme.advisory,
                                detail: ["USGS monitored status."], priority: 30))
            }
        }
        if let quakes = snapshot.quakes?.value,
           let nearest = quakes.events.min(by: { $0.coordinate.distanceMiles(to: here) < $1.coordinate.distanceMiles(to: here) }) {
            let miles = nearest.coordinate.distanceMiles(to: here)
            rows.append(Row(pid: 3301, system: String(format: "Quake M%.1f", nearest.magnitude), state: "REPORTED", distance: fmt.distance(miles: miles),
                            bearing: Compass.point(here.bearingDegrees(to: nearest.coordinate)), moving: "—", eta: Formatter.ago(nearest.time, now: ctx.now),
                            peak: String(format: "%.0f km deep", nearest.depthKM), color: Theme.faint, stateColor: Theme.faint,
                            detail: ["\(nearest.place). Nearest M2.5+ earthquake in the past 24 hours (USGS)."], priority: miles < 300 ? 200 : 3))
        }
        return rows.sorted { $0.priority > $1.priority }
    }
}

protocol FetchedError { var message: String { get } }
extension Fetched: FetchedError {
    var message: String { error ?? "Unavailable." }
}

extension WeatherAlert.Level {
    var hashRank: Int {
        switch self {
        case .statement: 0
        case .advisory: 1
        case .watch: 2
        case .warning: 3
        }
    }
}

extension WeatherAlert.Severity {
    var hashRank: Int {
        switch self {
        case .unknown: 0
        case .minor: 1
        case .moderate: 2
        case .severe: 3
        case .extreme: 4
        }
    }
}

extension String {
    func padding(_ width: Int) -> String { TextWidth.pad(self, to: width) }
    /// Truncates to leave one space, then pads: a fixed-width table cell.
    func cell(_ width: Int) -> String { TextWidth.pad(TextWidth.truncate(self, to: width - 1), to: width) }
}

extension TextWidth {
    /// Truncates text that may contain SGR sequences to `width` visible cells.
    static func truncateStyled(_ text: String, to width: Int) -> String {
        guard of(text) > width else { return text }
        var result = ""
        var visible = 0
        var inEscape = false
        for character in text {
            if character == "\u{1B}" { inEscape = true; result.append(character); continue }
            if inEscape {
                result.append(character)
                if let ascii = character.asciiValue, (0x40...0x7E).contains(ascii), character != "[" { inEscape = false }
                continue
            }
            let w = of(character)
            if visible + w > width { break }
            result.append(character)
            visible += w
        }
        return result + Styler.reset
    }
}
