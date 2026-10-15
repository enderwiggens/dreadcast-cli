import Foundation
import DreadcastKit
import DreadTerminal

/// `dread systems`: weather systems near you, listed like processes and sorted by
/// threat. At a terminal it opens the app on its Systems tab; piped, or with --plain,
/// --json or --pretty, it lists them once.
enum SystemsCommand {
    struct Row {
        enum Kind: String {
            case alert, rain, stormCell = "storm-cell", lightning, severeOutlook = "severe-outlook",
                 tropicalStorm = "tropical-storm", wildfire, airQuality = "air-quality", smoke, dust, volcano, earthquake
        }

        let pid: Int
        let kind: Kind
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
        /// Who reported it, such as "NWS" or the radar's credit; nil when unknown.
        var source: String?
        /// The distance in miles, when the row has one.
        var miles: Double?

        /// The name in the table, with active alerts marked.
        var label: String { kind == .alert && state == "ACTIVE" ? "▲ " + system : system }
    }

    static func run(_ ctx: Context) async throws -> ExitCode {
        if ctx.interactive { return try await DreadApp.run(ctx, tab: .systems) }
        let place = try await ctx.resolveLocation()
        let snapshot = await load(ctx, place: place)
        let fmt = Formatter(units: ctx.units, timeZone: snapshot.weather?.value?.timeZone ?? ctx.timeZone(for: place))
        let rows = buildRows(snapshot: snapshot, place: place, fmt: fmt, ctx: ctx)
        let read = sources(snapshot, place: place)
        switch ctx.mode {
        case .json:
            ctx.writeJSON(SystemsJSON(place: place, rows: rows, sources: read, now: ctx.now))
        case .plain:
            ctx.write(plain(place: place, rows: rows, sources: read, ctx: ctx))
        case .pretty:
            ctx.write(pretty(place: place, rows: rows, snapshot: snapshot, sources: read, fmt: fmt, ctx: ctx))
        }
        // As with the other commands, nothing but stale or missing data exits 3.
        return read.contains { $0.loaded && !$0.stale } ? .ok : .unavailable
    }

    /// Everything the Systems tab reads, loaded once.
    static func load(_ ctx: Context, place: Place) async -> LiveData.Snapshot {
        async let weather = ctx.weather(place)
        async let alerts = ctx.alerts(place)
        async let lightning = ctx.lightning(place)
        async let nowcast = ctx.nowcast(place)
        async let severe = ctx.severeRisk(place)
        async let tropical = ctx.tropical()
        async let fires = ctx.wildfires(place)
        async let air = ctx.airQuality(place)
        async let hazards = ctx.hazards(place)
        async let quakes = ctx.earthquakes()
        var snapshot = LiveData.Snapshot()
        snapshot.lightningConfigured = Credentials.xweather(environment: ctx.environment) != nil
        snapshot.weather = await weather
        snapshot.alerts = await alerts
        snapshot.lightning = await lightning
        snapshot.nowcast = await nowcast
        snapshot.severe = await severe
        snapshot.tropical = await tropical
        snapshot.fires = await fires
        snapshot.air = await air
        snapshot.hazards = await hazards
        snapshot.quakes = await quakes
        return snapshot
    }

    /// A source the systems come from, and whether it answered.
    struct Source {
        /// For JSON and messages: "alerts", "radar", "tropical-storms" and so on.
        let id: String
        let providers: [String]
        let loaded: Bool
        let error: String?
        let stale: Bool
        let storedAt: Date?

        var name: String { id.replacingOccurrences(of: "-", with: " ") }
    }

    /// The sources read for a place, leaving out any that don't cover it or aren't set up.
    static func sources(_ snapshot: LiveData.Snapshot, place: Place) -> [Source] {
        var list: [Source] = []
        func add<T>(_ id: String, _ providers: [String], _ fetched: Fetched<T>?) {
            guard let fetched else { return }
            list.append(Source(id: id, providers: providers, loaded: fetched.value != nil, error: fetched.value == nil ? fetched.error : nil,
                               stale: fetched.isStale, storedAt: fetched.storedAt))
        }
        let us = place.isUnitedStates
        add("conditions", ["Open-Meteo"], snapshot.weather)
        if us { add("alerts", ["NWS"], snapshot.alerts) }
        add("radar", snapshot.nowcast?.value.map { [$0.radarCredit] } ?? [], snapshot.nowcast)
        if snapshot.lightningConfigured { add("lightning", ["Xweather"], snapshot.lightning) }
        if us { add("severe-outlook", ["NOAA SPC"], snapshot.severe) }
        add("tropical-storms", ["NHC"], snapshot.tropical)
        if us { add("wildfires", ["NIFC"], snapshot.fires) }
        add("air-quality", ["Open-Meteo"], snapshot.air)
        // Hazards load together but fail one by one; the list uses three of them.
        if let hazards = snapshot.hazards {
            for (kind, provider) in [(HazardKind.smoke, "NOAA HMS"), (.dust, "Open-Meteo"), (.volcanoes, "USGS")] {
                let failure = hazards.value.map { $0.failures[kind.rawValue] } ?? (hazards.error ?? "Unavailable.")
                list.append(Source(id: kind.rawValue, providers: [provider], loaded: failure == nil, error: failure,
                                   stale: hazards.isStale, storedAt: hazards.storedAt))
            }
        }
        add("earthquakes", ["USGS"], snapshot.quakes)
        return list
    }

    // MARK: The Systems tab

    /// Meters, the threat-sorted table and the selected row's details, sized to fit.
    static func lines(ctx: Context, place: Place, snapshot: LiveData.Snapshot, selected requested: Int,
                      width: Int, height: Int) -> (lines: [String], selected: Int) {
        let s = ctx.styler
        let zone = snapshot.weather?.value?.timeZone ?? ctx.timeZone(for: place)
        let fmt = Formatter(units: ctx.units, timeZone: zone)
        var lines = meters(snapshot: snapshot, fmt: fmt, ctx: ctx, width: width)
        lines.append("")

        let rows = buildRows(snapshot: snapshot, place: place, fmt: fmt, ctx: ctx)
        let selected = min(max(0, requested), max(0, rows.count - 1))
        lines.append(tableHeader(width: width, styler: s))
        let detailHeight = 4
        let available = max(3, height - lines.count - detailHeight)
        let start = max(0, min(selected - available + 1, rows.count - available))
        for (index, row) in rows.enumerated().dropFirst(start).prefix(available) {
            lines.append(tableRow(row, selected: index == selected, width: width, styler: s))
        }
        while lines.count < height - detailHeight { lines.append("") }

        let detail = rows.isEmpty ? ["Waiting for data…"] : rows[selected].detail
        let title = rows.isEmpty ? "" : " \(rows[selected].pid) \(rows[selected].label) "
        lines.append(s.paint("──" + title + String(repeating: "─", count: max(0, width - TextWidth.of(title) - 3)), Theme.faint))
        for line in detail.flatMap({ TextWidth.wrap($0, width: width - 4) }).prefix(detailHeight - 1) {
            lines.append("  " + line)
        }
        return (Array(lines.prefix(height)), selected)
    }

    static func tableHeader(width: Int, styler s: Styler) -> String {
        let header = " " + "PID".padding(6) + "SYSTEM".padding(28) + "STATE".padding(11) + "DIST".padding(9) + "BRG".padding(5) + "MOVING".padding(9) + "ETA".padding(13) + "PEAK"
        return s.paint(TextWidth.pad(header, to: width), TextStyle(foreground: Theme.mist, background: RGB(hex: 0x182B40), bold: true))
    }

    static func tableRow(_ row: Row, selected: Bool, width: Int, styler s: Styler) -> String {
        var text = " " + String(row.pid).padding(6) + row.label.cell(28)
        let stateText = row.state.cell(11)
        let rest = row.distance.cell(9) + row.bearing.cell(5) + row.moving.cell(9) + row.eta.cell(13) + row.peak
        if selected {
            text += stateText + rest
            return s.paint(TextWidth.pad(TextWidth.truncate(text, to: width), to: width), TextStyle(foreground: Theme.porcelain, background: RGB(hex: 0x1C3350), bold: true))
        }
        let color = row.color ?? Theme.porcelain
        return s.paint(text, color) + s.paint(stateText, row.stateColor ?? color) + s.paint(rest, row.color ?? Theme.mist)
    }

    // MARK: Listed once

    /// The meters, then every system with its details beneath it, then the sources.
    static func pretty(place: Place, rows: [Row], snapshot: LiveData.Snapshot, sources: [Source], fmt: Formatter, ctx: Context) -> [String] {
        let s = ctx.styler
        let width = min(max(ctx.terminal.columns - 1, 60), 120)
        // Meters and table rows are cut to the width, as in the app; without color, with
        // no escape codes either.
        func fit(_ line: String) -> String {
            s.mode == .none ? TextWidth.truncate(line, to: width, ellipsis: "") : TextWidth.truncateStyled(line, to: width)
        }
        var lines = ["", TextWidth.spread(ctx.title("SYSTEMS", place: place),
                                          s.paint(fmt.time(ctx.now) + " " + fmt.zoneAbbreviation(ctx.now), Theme.faint), width: width), ""]
        lines += meters(snapshot: snapshot, fmt: fmt, ctx: ctx, width: width).map(fit)
        lines += ["", fit(tableHeader(width: width, styler: s))]
        if rows.isEmpty { lines.append("  " + s.paint("No systems to list.", Theme.mist)) }
        for row in rows {
            lines.append(fit(tableRow(row, selected: false, width: width, styler: s)))
            lines += row.detail.flatMap { TextWidth.wrap($0, width: width - 8) }.map { "       " + s.paint($0, Theme.mist) }
        }
        lines.append("")

        let loaded = sources.filter(\.loaded), stale = sources.filter(\.stale), missing = sources.filter { !$0.loaded }
        // Credits wrap rather than being cut.
        if !loaded.isEmpty {
            let names = providers(loaded).joined(separator: " · ").uppercased()
            let updated = stale.isEmpty ? loaded.compactMap(\.storedAt).min().map { "updated " + Formatter.ago($0, now: ctx.now) } ?? ""
                : "stale: " + stale.map(\.name).joined(separator: ", ")
            let age = s.paint(updated, stale.isEmpty ? Theme.faint : Theme.advisory)
            if TextWidth.of(names) + TextWidth.of(updated) + 4 <= width {
                lines.append(TextWidth.spread("  " + s.paint(names, Theme.faint), age, width: width))
            } else {
                lines += TextWidth.wrap(names, width: width - 2).map { "  " + s.paint($0, Theme.faint) } + ["  " + age]
            }
        }
        if !missing.isEmpty {
            lines += TextWidth.wrap("Unavailable: \(missing.map(\.name).joined(separator: ", ")). This is not an all-clear.", width: width - 2)
                .map { "  " + s.paint($0, Theme.advisory) }
        }
        lines.append("")
        return lines
    }

    /// One line per system, most serious first, then the sources.
    static func plain(place: Place, rows: [Row], sources: [Source], ctx: Context) -> [String] {
        var lines = ["Weather systems near \(place.name), most serious first."]
        if rows.isEmpty { lines.append("No systems to list.") }
        for row in rows {
            let distance = [row.distance, row.bearing].filter { $0 != "—" }.joined(separator: " ")
            let cells = [row.state, distance, row.moving == "—" ? "" : "moving " + row.moving, row.eta, row.peak].filter { !$0.isEmpty && $0 != "—" }
            lines.append("\(row.system) (\(cells.joined(separator: ", "))).\(row.detail.map { " " + sentence($0) }.joined())")
        }
        let loaded = sources.filter(\.loaded), stale = sources.filter(\.stale), missing = sources.filter { !$0.loaded }
        if let oldest = loaded.compactMap(\.storedAt).min() {
            lines.append("Sources: \(providers(loaded).joined(separator: ", ")). Updated \(Formatter.ago(oldest, now: ctx.now)).")
        }
        if !stale.isEmpty { lines.append("Stale: \(stale.map(\.name).joined(separator: ", ")).") }
        if !missing.isEmpty { lines.append("Unavailable: \(missing.map(\.name).joined(separator: ", ")). This is not an all-clear.") }
        return lines
    }

    /// Each provider once, in the order the sources are read.
    static func providers(_ sources: [Source]) -> [String] {
        var names: [String] = []
        for name in sources.flatMap(\.providers) where !names.contains(name) { names.append(name) }
        return names
    }

    /// Text ending in a full stop, for details that are fragments.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }

    static func meters(snapshot: LiveData.Snapshot, fmt: Formatter, ctx: Context, width: Int) -> [String] {
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
        } else if snapshot.weather == nil {
            right = [s.paint("Conditions loading…", Theme.faint), "", ""]
        } else {
            right = [s.paint("Conditions unavailable", Theme.advisory), "", ""]
        }
        return zip(left, right).map { $0 + "  " + $1 }
    }

    static func buildRows(snapshot: LiveData.Snapshot, place: Place, fmt: Formatter, ctx: Context) -> [Row] {
        var rows: [Row] = []
        let here = place.coordinate
        func unavailable(_ pid: Int, _ kind: Row.Kind, _ system: String, _ fetched: (any FetchedError)?, priority: Int, source: String?) {
            rows.append(Row(pid: pid, kind: kind, system: system, state: "UNAVAILABLE", distance: "—", bearing: "—", moving: "—", eta: "—", peak: "—",
                            color: Theme.faint, stateColor: Theme.advisory, detail: [fetched?.message ?? "Not loaded yet."], priority: priority, source: source))
        }

        // Alerts first: hazard, area, time and the official instruction.
        if let alerts = snapshot.alerts {
            if let list = alerts.value {
                for (i, alert) in list.enumerated() {
                    let color = NowCommand.alertColor(alert)
                    rows.append(Row(pid: 9001 + i, kind: .alert, system: alert.event, state: "ACTIVE", distance: "here", bearing: "—", moving: "—",
                                    eta: alert.endsOrExpires.map { "til " + fmt.time($0) } ?? "—", peak: alert.severity.rawValue,
                                    color: color, stateColor: color,
                                    detail: [alert.headline, alert.instruction.flatMap(NowCommand.firstSentence) ?? "", "Area: \(alert.areaDescription)"].filter { !$0.isEmpty },
                                    priority: 1000 + alert.level.hashRank * 100 + alert.severity.hashRank, source: "NWS"))
                }
            } else if place.isUnitedStates {
                unavailable(9000, .alert, "NWS alerts", alerts, priority: 900, source: "NWS")
            }
        }

        // Radar: rain timing and strong cells.
        if let nowcast = snapshot.nowcast {
            if let n = nowcast.value {
                let moving = n.motionBearing.map { Compass.octant($0) + " " + String(Int((n.motionMPH ?? 0).rounded())) } ?? "—"
                if n.isRainingNow {
                    rows.append(Row(pid: 8800, kind: .rain, system: "Rain overhead", state: RainRate.Intensity(dbz: n.currentDBZ ?? 0).label.uppercased(), distance: "here", bearing: "—",
                                    moving: moving, eta: n.endMinutes.map { "ends ~\($0)m" } ?? "2 h+", peak: n.peakDBZ.map { "\(Int($0)) dBZ" } ?? "—",
                                    color: Theme.rain, stateColor: Theme.rain, detail: [EtaCommand.headline(n, fmt: fmt, ctx: ctx, styled: false)], priority: 700,
                                    source: n.radarCredit))
                } else if let arrival = n.arrivalMinutes {
                    rows.append(Row(pid: 8800, kind: .rain, system: "Rain approaching", state: "MOVING",
                                    distance: n.nearestEchoMiles.map { fmt.distance(miles: $0) } ?? "—", bearing: n.nearestEchoBearing.map { Compass.point($0) } ?? "—",
                                    moving: moving, eta: "\(arrival) min", peak: n.peakDBZ.map { "\(Int($0)) dBZ" } ?? "—",
                                    color: nil, stateColor: Theme.lightning[1], detail: [EtaCommand.headline(n, fmt: fmt, ctx: ctx, styled: false), "Confidence: \(n.confidence.rawValue)."], priority: 600 - arrival,
                                    source: n.radarCredit, miles: n.nearestEchoMiles))
                } else {
                    rows.append(Row(pid: 8800, kind: .rain, system: n.nearestEchoMiles == nil ? "No rain nearby" : "Nearest rain", state: n.nearestEchoMiles == nil ? "CLEAR" : "DISTANT",
                                    distance: n.nearestEchoMiles.map { fmt.distance(miles: $0) } ?? "—", bearing: n.nearestEchoBearing.map { Compass.point($0) } ?? "—",
                                    moving: moving, eta: "—", peak: "—", color: Theme.mist, stateColor: Theme.mint,
                                    detail: [EtaCommand.headline(n, fmt: fmt, ctx: ctx, styled: false)],
                                    priority: n.nearestEchoMiles.map { $0 < 50 ? 400 - Int($0 * 2) : 100 } ?? 100, source: n.radarCredit, miles: n.nearestEchoMiles))
                }
                for (i, cell) in n.cells.prefix(4).enumerated() {
                    let eta = cell.arrivalMinutes.map { "\($0) min" } ?? cell.closestApproachMinutes.map { "passes \($0)m" } ?? "—"
                    var detail = "Strongest echo \(Int(cell.maxDBZ)) dBZ, about \(Int(cell.areaSquareMiles.rounded())) sq mi of heavy rain."
                    if let miss = cell.closestApproachMiles, let minutes = cell.closestApproachMinutes {
                        detail += " Closest approach \(fmt.distance(miles: miss)) in about \(minutes) min."
                    }
                    rows.append(Row(pid: 8801 + i, kind: .stormCell, system: "Storm cell C\(cell.id)", state: n.trend == .intensifying ? "GROWING" : n.trend == .weakening ? "WEAKENING" : "STEADY",
                                    distance: fmt.distance(miles: cell.distanceMiles), bearing: Compass.point(cell.bearing), moving: moving, eta: eta,
                                    peak: "\(Int(cell.maxDBZ)) dBZ", color: nil, stateColor: Theme.lightning[cell.maxDBZ >= 50 ? 2 : 1],
                                    detail: [detail, "Radar frames end \(n.latestFrame.map(fmt.time) ?? "--"). Motion is shared by all echoes."],
                                    priority: 500 + (cell.arrivalMinutes.map { 120 - min(120, $0) } ?? 0) - Int(cell.distanceMiles),
                                    source: n.radarCredit, miles: cell.distanceMiles))
                }
            } else {
                unavailable(8800, .rain, "Radar", nowcast, priority: 300, source: nil)
            }
        }

        if snapshot.lightningConfigured, let lightning = snapshot.lightning {
            if let snap = lightning.value {
                let strikes = snap.current(at: ctx.now)
                let nearest = snap.nearest(at: ctx.now)
                rows.append(Row(pid: 8790, kind: .lightning, system: "Lightning", state: strikes.isEmpty ? "QUIET" : "ACTIVE",
                                distance: nearest.map { fmt.distance(miles: $0.miles) } ?? "—",
                                bearing: nearest.map { Compass.point(snap.center.bearingDegrees(to: $0.strike.coordinate)) } ?? "—",
                                moving: "—", eta: "—", peak: "\(strikes.count) in 20 min", color: nil, stateColor: strikes.isEmpty ? Theme.mint : Theme.lightning[0],
                                detail: ["\(strikes.count) strikes within \(fmt.distance(miles: snap.radiusMiles)) in the last 20 minutes (Xweather)."],
                                priority: strikes.isEmpty ? 50 : 650 - Int(nearest?.miles ?? 60), source: "Xweather", miles: nearest?.miles))
            } else {
                unavailable(8790, .lightning, "Lightning", lightning, priority: 200, source: "Xweather")
            }
        }

        if let severe = snapshot.severe, place.isUnitedStates {
            if let risk = severe.value {
                rows.append(Row(pid: 5120, kind: .severeOutlook, system: "SPC Day 1 outlook", state: risk.risk == .thunder ? "T-STORMS" : risk.risk.label.uppercased(), distance: "area", bearing: "—", moving: "—",
                                eta: risk.expires.map { "til " + fmt.time($0) } ?? "—", peak: risk.risk.level.map { "level \($0) of 5" } ?? "—",
                                color: risk.risk >= .slight ? nil : Theme.mist, stateColor: risk.risk >= .slight ? Theme.advisory : Theme.mist,
                                detail: ["Storm Prediction Center categorical risk for today at this location: \(risk.risk.label.lowercased())."],
                                priority: risk.risk >= .slight ? 400 + risk.risk.rawValue : 20, source: "NOAA SPC"))
            } else {
                unavailable(5120, .severeOutlook, "SPC outlook", severe, priority: 10, source: "NOAA SPC")
            }
        }

        if let storms = snapshot.tropical?.value {
            for (i, storm) in storms.enumerated() where storm.coordinate.distanceMiles(to: here) <= 1500 {
                let miles = storm.coordinate.distanceMiles(to: here)
                rows.append(Row(pid: 7001 + i, kind: .tropicalStorm, system: storm.title, state: "TRACKING",
                                distance: fmt.distance(miles: miles), bearing: Compass.point(here.bearingDegrees(to: storm.coordinate)), moving: "—", eta: "—",
                                peak: storm.maximumWindKnots.map { "\($0) kt" } ?? "—", color: Theme.mint, stateColor: Theme.mint,
                                detail: ["NHC advisory \(storm.advisory ?? ""). Follow the NHC and local officials for forecasts."],
                                priority: 300 + Int(max(0, 1500 - miles) / 10), source: "NHC", miles: miles))
            }
        }

        if let fires = snapshot.fires?.value {
            for (i, fire) in fires.prefix(3).enumerated() {
                let miles = fire.coordinate.distanceMiles(to: here)
                rows.append(Row(pid: 6001 + i, kind: .wildfire, system: "Fire: " + fire.name, state: fire.percentContained.map { "\($0)% CONT" } ?? "ACTIVE",
                                distance: fmt.distance(miles: miles), bearing: Compass.point(here.bearingDegrees(to: fire.coordinate)), moving: "—", eta: "—",
                                peak: fire.acres.flatMap { $0 >= 1 ? fmt.grouped(Int($0)) + " ac" : nil } ?? "—", color: RGB(hex: 0xFFB66D), stateColor: RGB(hex: 0xFFB66D),
                                detail: ["NIFC incident \(fire.name)\(fire.state.map { ", \($0)" } ?? ""). Discovered \(fire.discoveredAt.map { fmt.day($0) } ?? "date unknown")."],
                                priority: 120 + Int(max(0, 100 - miles)), source: "NIFC", miles: miles))
            }
        }

        if let air = snapshot.air?.value {
            rows.append(Row(pid: 4401, kind: .airQuality, system: "Air quality", state: air.category.uppercased().prefix(10).description, distance: "here", bearing: "—", moving: "—", eta: "—",
                            peak: "AQI \(air.usAQI)", color: Theme.mist, stateColor: air.usAQI > 100 ? Theme.warning : air.usAQI > 50 ? Theme.advisory : Theme.mint,
                            detail: ["US AQI \(air.usAQI) (\(air.category.lowercased())), modeled by CAMS via Open-Meteo."], priority: air.usAQI > 100 ? 350 : 15,
                            source: "CAMS via Open-Meteo"))
        }
        if let hazards = snapshot.hazards?.value {
            if let smoke = hazards.smokeAtLocation {
                rows.append(Row(pid: 4402, kind: .smoke, system: "Smoke (NOAA HMS)", state: smoke.uppercased(), distance: smoke == "none" ? "—" : "aloft", bearing: "—", moving: "—", eta: "—",
                                peak: "not at surface", color: Theme.faint, stateColor: smoke == "none" ? Theme.faint : Theme.advisory,
                                detail: ["Satellite-analyzed smoke over your location. This is not a surface air-quality measurement."], priority: smoke == "none" ? 5 : 150,
                                source: "NOAA HMS"))
            }
            if let dust = hazards.dust {
                rows.append(Row(pid: 4403, kind: .dust, system: "Dust (CAMS)", state: dust > 100 ? "ELEVATED" : "LOW", distance: "area", bearing: "—", moving: "—", eta: "—",
                                peak: String(format: "%.0f µg/m³", dust), color: Theme.faint, stateColor: dust > 100 ? Theme.advisory : Theme.faint,
                                detail: ["Modeled dust concentration near the surface."], priority: dust > 100 ? 140 : 4, source: "CAMS via Open-Meteo"))
            }
            if let volcano = hazards.elevatedVolcanoes?.first, let miles = volcano.distanceMiles, miles < 1500 {
                rows.append(Row(pid: 4404, kind: .volcano, system: "Volcano: " + volcano.title, state: volcano.level.uppercased(), distance: fmt.distance(miles: miles), bearing: "—",
                                moving: "—", eta: "—", peak: volcano.detail ?? "—", color: Theme.mist, stateColor: Theme.advisory,
                                detail: ["USGS monitored status."], priority: 30, source: "USGS", miles: miles))
            }
        }
        if let quakes = snapshot.quakes?.value,
           let nearest = quakes.events.min(by: { $0.coordinate.distanceMiles(to: here) < $1.coordinate.distanceMiles(to: here) }) {
            let miles = nearest.coordinate.distanceMiles(to: here)
            rows.append(Row(pid: 3301, kind: .earthquake, system: String(format: "Quake M%.1f", nearest.magnitude), state: "REPORTED", distance: fmt.distance(miles: miles),
                            bearing: Compass.point(here.bearingDegrees(to: nearest.coordinate)), moving: "—", eta: Formatter.ago(nearest.time, now: ctx.now),
                            peak: String(format: "%.0f km deep", nearest.depthKM), color: Theme.faint, stateColor: Theme.faint,
                            detail: ["\(nearest.place). Nearest M2.5+ earthquake in the past 24 hours (USGS)."], priority: miles < 300 ? 200 : 3,
                            source: "USGS", miles: miles))
        }
        return rows.sorted { $0.priority > $1.priority }
    }
}

/// `dread systems --json`: the systems, most serious first, and the sources that couldn't
/// be read. Distances, bearings and times are as the table shows them, in your units;
/// `distanceMiles` is the number behind a distance.
struct SystemsJSON: Encodable {
    struct System: Encodable {
        let pid: Int
        let kind: String
        let name: String
        let state: String
        let distance: String?
        let distanceMiles: Double?
        let bearing: String?
        let moving: String?
        let eta: String?
        let peak: String?
        let detail: [String]
        let source: String?
    }
    struct Problem: Encodable { let source: String; let error: String }

    let schema = "dreadcast.systems/1"
    let generatedAt: Date
    let location: LocationJSON
    let systems: [System]
    let unavailable: [Problem]
    let stale: [String]

    init(place: Place, rows: [SystemsCommand.Row], sources: [SystemsCommand.Source], now: Date) {
        generatedAt = now
        location = LocationJSON(place)
        func cell(_ text: String) -> String? { text == "—" ? nil : text }
        systems = rows.map {
            System(pid: $0.pid, kind: $0.kind.rawValue, name: $0.system, state: $0.state, distance: cell($0.distance),
                   distanceMiles: $0.miles.map { ($0 * 10).rounded() / 10 }, bearing: cell($0.bearing), moving: cell($0.moving),
                   eta: cell($0.eta), peak: cell($0.peak), detail: $0.detail, source: $0.source)
        }
        unavailable = sources.filter { !$0.loaded }.map { Problem(source: $0.id, error: $0.error ?? "Unavailable.") }
        stale = sources.filter(\.stale).map(\.id)
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
