import Foundation
import DreadcastKit
import DreadTerminal

/// `dread` (or `dread weather`): your scene, current conditions, active alerts, the
/// next two hours, recent lightning and the next five days.
enum NowCommand {
    static func run(_ ctx: Context) async throws -> ExitCode {
        let place = try await ctx.resolveLocation()
        async let weatherResult = ctx.weather(place)
        async let alertsResult = ctx.alerts(place)
        async let lightningResult = ctx.lightning(place)
        let (weather, alerts, lightning) = await (weatherResult, alertsResult, lightningResult)
        let nowcast = ctx.cached(Nowcast.self, key: "nowcast-\(Context.placeKey(place))")
            .flatMap { ctx.now.timeIntervalSince($0.storedAt) < 600 ? $0.value : nil }

        switch ctx.mode {
        case .json:
            ctx.writeJSON(NowJSON(place: place, weather: weather, alerts: alerts, lightning: lightning,
                                  nowcast: nowcast, now: ctx.now))
        case .plain:
            ctx.write(plain(place: place, weather: weather, alerts: alerts, lightning: lightning, nowcast: nowcast, ctx: ctx))
        case .pretty:
            ctx.write(pretty(place: place, weather: weather, alerts: alerts, lightning: lightning, nowcast: nowcast, ctx: ctx))
        }
        return weather.value == nil ? .unavailable : .ok
    }

    // MARK: Pretty

    /// `width` and `rows` default to the terminal; the app passes its own. `sceneTime`
    /// animates the banner in slow steps instead of a still frame.
    static func pretty(place: Place, weather: Fetched<WeatherReport>, alerts: Fetched<[WeatherAlert]>,
                       lightning: Fetched<LightningSnapshot>?, nowcast: Nowcast?, ctx: Context,
                       width requested: Int? = nil, rows: Int? = nil, sceneTime: Double? = nil) -> [String] {
        let s = ctx.styler
        let width = requested ?? min(max(ctx.terminal.columns - 2, 60), 86)
        let report = weather.value
        let fmt = Formatter(units: ctx.units, timeZone: report?.timeZone ?? ctx.timeZone(for: place))
        var lines: [String] = [""]
        let art = banner(place: place, alerts: alerts, report: report, ctx: ctx, width: width, rows: rows, sceneTime: sceneTime)
        if !art.isEmpty { lines.append(contentsOf: art + [""]) }

        let brand = "  " + s.paint("DREADCAST", Theme.porcelain, bold: true) + s.paint("  ·  ", Theme.faint) + place.name
        let clock = s.paint(fmt.time(ctx.now) + " " + fmt.zoneAbbreviation(ctx.now), Theme.faint)
        if !ctx.inApp { lines.append(TextWidth.spread(brand, clock, width: width)) }

        if let report {
            let c = report.current
            let left = "  " + ctx.icon(c.weatherCode, isDay: c.isDay) + "  " + s.bold(fmt.temperature(c.temperature, unit: true))
                + "  " + WeatherCondition.description(c.weatherCode)
            let right = s.paint("Feels \(fmt.temperature(c.apparentTemperature)) · Humidity \(fmt.percent(c.humidity)) · Wind \(fmt.wind(speed: c.windSpeed, gust: c.windGusts, direction: c.windDirection))", Theme.mist)
            if TextWidth.of(left) + TextWidth.of(right) + 2 <= width {
                lines.append(TextWidth.spread(left, right, width: width))
            } else {
                lines.append(left)
                lines.append("      " + right)
            }
        } else {
            lines.append("  " + s.paint("Current conditions are unavailable. \(weather.error ?? "")", Theme.warning))
        }
        lines.append("")

        // Alerts: hazard, time and the official instruction. No jokes here.
        var alertsActive = false
        if let list = alerts.value {
            alertsActive = !list.isEmpty
            if list.isEmpty {
                let note = alerts.isStale ? "No alerts as of \(Formatter.ago(alerts.storedAt ?? ctx.now, now: ctx.now)); refresh failed." : "No active alerts for this location."
                lines.append(TextWidth.spread("  " + s.paint(note, alerts.isStale ? Theme.advisory : Theme.mint), s.paint("NWS", Theme.faint), width: width))
            } else {
                for alert in list.prefix(2) {
                    lines.append(contentsOf: alertLines(alert, fmt: fmt, ctx: ctx, width: width))
                }
                if list.count > 2 {
                    lines.append("  " + s.paint("+\(list.count - 2) more · dread alerts", Theme.faint))
                }
            }
        } else if place.isUnitedStates {
            lines.append("  " + s.paint("Alerts unavailable: \(alerts.error ?? "unknown error"). This is not an all-clear.", Theme.advisory))
        } else {
            lines.append("  " + s.paint("Official alerts are available for US locations.", Theme.faint))
        }
        lines.append("")

        if let report {
            lines.append(nextTwoHours(report: report, nowcast: nowcast, fmt: fmt, ctx: ctx))
        }
        if let lightning {
            lines.append(lightningLine(lightning, fmt: fmt, ctx: ctx))
        }
        if let report {
            lines.append(dayLine(report: report, fmt: fmt, ctx: ctx))
            let days = DayRows.upcoming(report, from: ctx.now, count: 5)
            if !days.isEmpty {
                lines.append("")
                lines.append("  " + s.bold("NEXT 5 DAYS") + s.paint("   low · high · chance of rain", Theme.faint))
                lines.append(contentsOf: DayRows.lines(days, fmt: fmt, ctx: ctx, barWidth: 16))
            }
        }
        lines.append("")

        var sources = ["OPEN-METEO"]
        if place.isUnitedStates { sources.append("NWS") }
        if lightning != nil { sources.append("XWEATHER") }
        if nowcast != nil { sources.append("RAINVIEWER") }
        let updated: String
        if let stored = weather.storedAt {
            updated = (weather.isStale ? "stale · " : "") + "updated " + Formatter.ago(stored, now: ctx.now)
        } else {
            updated = "not updated"
        }
        lines.append(TextWidth.spread("  " + s.paint(sources.joined(separator: " · "), Theme.faint), s.paint(updated, weather.isStale ? Theme.advisory : Theme.faint), width: width))
        if let report, ctx.quipsEnabled, let quip = Quip.line(report: report, alertsActive: alertsActive, now: ctx.now) {
            lines.append("  " + s.paint(quip, Theme.lime, italic: true))
        }
        lines.append("")
        return lines
    }

    /// Your scene as a strip above the readings. It is decorative, so it steps aside
    /// for active or unknown alerts, plain output and short terminals.
    static func banner(place: Place, alerts: Fetched<[WeatherAlert]>, report: WeatherReport?, ctx: Context, width: Int,
                       rows: Int? = nil, sceneTime: Double? = nil) -> [String] {
        guard ctx.styler.mode >= .ansi256, !ctx.arguments.has("no-scene"), width >= 50,
              (rows ?? ctx.terminal.rows) >= bannerMinimumRows else { return [] }
        if place.isUnitedStates, alerts.value?.isEmpty != true { return [] }
        let zone = report?.timeZone ?? ctx.timeZone(for: place)
        guard ctx.config.sceneBanner else { return [] }
        let scene = SceneCommand.configuredScene(ctx, timeZone: zone)
        let period = ScenePeriod.at(ctx.now, timeZone: zone)
        let strip = ScenePainter(scene: scene, period: period, time: sceneTime ?? 0, still: sceneTime == nil || ctx.terminal.reduceMotion,
                                 moon: LunarPhase(at: ctx.now), layout: .strip)
            .paint(width: width - 2, height: 20)
        return HalfBlockFrame(raster: strip).lines(styler: ctx.styler).map { "  " + $0 }
    }

    /// The banner adds eleven lines; below this height the readings would scroll away.
    static let bannerMinimumRows = 38

    static func alertColor(_ alert: WeatherAlert) -> RGB {
        switch alert.level {
        case .warning: return alert.severity >= .extreme ? Theme.urgent : Theme.warning
        case .watch: return Theme.advisory
        case .advisory: return Theme.information
        case .statement: return Theme.mist
        }
    }

    static func alertLines(_ alert: WeatherAlert, fmt: Formatter, ctx: Context, width: Int) -> [String] {
        let s = ctx.styler
        let color = alertColor(alert)
        let label = "▲ " + alert.event.uppercased()
        let badge = s.isEnabled
            ? s.paint(" \(label) ", TextStyle(foreground: Theme.midnight, background: color, bold: true))
            : label
        var left = "  " + badge
        if let end = alert.endsOrExpires {
            left += "  " + s.paint("until \(fmt.until(end, now: ctx.now)) \(fmt.zoneAbbreviation(end))", color)
        }
        var lines = [TextWidth.spread(left, s.paint(alert.sender ?? "NWS", Theme.faint), width: width)]
        let detail = alert.instruction.flatMap(firstSentence) ?? firstSentence(alert.headline) ?? alert.headline
        for line in TextWidth.wrap(detail, width: width - 4).prefix(2) {
            lines.append("    " + s.paint(line, Theme.mist))
        }
        return lines
    }

    static func firstSentence(_ text: String) -> String? {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        if let range = cleaned.range(of: ". ") { return String(cleaned[..<range.lowerBound]) + "." }
        return cleaned
    }

    static func nextTwoHours(report: WeatherReport, nowcast: Nowcast?, fmt: Formatter, ctx: Context) -> String {
        let s = ctx.styler
        let label = "  " + s.paint("Next 2 h    ", Theme.mist)
        if let nowcast, !nowcast.steps.isEmpty {
            let values = stride(from: 0, to: min(nowcast.steps.count, 60), by: 2).map { nowcast.steps[$0].dbz }
            let spark = colorSpark(values.map { $0.map { max(0, ($0 - 15) / 40) } }, ctx: ctx)
            return label + spark + "   " + nowcastSummary(nowcast, fmt: fmt, ctx: ctx)
        }
        let steps = report.minutely.filter { $0.time >= ctx.now.addingTimeInterval(-900) }.prefix(8)
        guard !steps.isEmpty else { return label + s.paint("no short-range forecast available", Theme.faint) }
        let scale = report.units == .imperial ? 0.08 : 2.0
        let fractions = steps.flatMap { step -> [Double?] in
            let f = (step.precipitation ?? 0) / scale
            return [f, f, f, f]
        }
        let spark = colorSpark(fractions, ctx: ctx)
        let threshold = report.units == .imperial ? 0.004 : 0.1
        if let first = steps.first(where: { ($0.precipitation ?? 0) >= threshold }) {
            let when = first.time <= ctx.now ? "rain now" : "rain from ~\(fmt.time(first.time))"
            return label + spark + "   " + when + s.paint(" (forecast)", Theme.faint)
        }
        return label + spark + "   no rain expected" + s.paint(" (forecast)", Theme.faint)
    }

    static func nowcastSummary(_ nowcast: Nowcast, fmt: Formatter, ctx: Context) -> String {
        let s = ctx.styler
        if nowcast.isRainingNow {
            if let end = nowcast.endMinutes { return "rain now, easing in ~\(Formatter.duration(minutes: end))" }
            return "rain now"
        }
        if let arrival = nowcast.arrivalMinutes {
            let time = fmt.time(ctx.now.addingTimeInterval(Double(arrival) * 60))
            var text = "rain from " + s.bold("~\(time)")
            if nowcast.heavyMinutes > 0 { text += ", heavy ~\(nowcast.heavyMinutes) min" }
            return text
        }
        return "no rain approaching" + s.paint(" (radar)", Theme.faint)
    }

    static func colorSpark(_ fractions: [Double?], ctx: Context) -> String {
        let s = ctx.styler
        return fractions.map { fraction -> String in
            guard let fraction else { return " " }
            let character = String(Charts.block(fraction, minimum: true))
            let color: RGB = fraction > 0.66 ? Theme.lightning[2] : fraction > 0.4 ? Theme.lightning[1] : fraction > 0.04 ? Theme.rain : Theme.faint
            return s.paint(character, color)
        }.joined()
    }

    static func lightningLine(_ fetched: Fetched<LightningSnapshot>, fmt: Formatter, ctx: Context) -> String {
        let s = ctx.styler
        let label = "  " + s.paint("Lightning   ", Theme.mist)
        guard let snapshot = fetched.value else {
            return label + s.paint("unavailable: \(fetched.error ?? "unknown error")", Theme.advisory)
        }
        let strikes = snapshot.current(at: ctx.now)
        guard let nearest = snapshot.nearest(at: ctx.now) else {
            return label + "none within \(fmt.distance(miles: snapshot.radiusMiles)) in 20 min"
        }
        let bearing = Compass.point(snapshot.center.bearingDegrees(to: nearest.strike.coordinate))
        return label + s.paint("\(strikes.count)", Theme.lightning[0]) + " in 20 min · nearest "
            + s.paint("\(fmt.distance(miles: nearest.miles)) \(bearing)", Theme.lightning[0])
            + s.paint("  \(Formatter.ago(nearest.strike.timestamp, now: ctx.now))", Theme.faint)
    }

    static func dayLine(report: WeatherReport, fmt: Formatter, ctx: Context) -> String {
        let s = ctx.styler
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = report.timeZone
        let hour = calendar.component(.hour, from: ctx.now)
        if (5..<16).contains(hour), let today = report.day(containing: ctx.now) {
            var parts = ["High \(fmt.temperature(today.high))", WeatherCondition.description(today.weatherCode)]
            if let p = today.precipitationProbability, p >= 20 { parts.append("\(Int(p))% chance of rain") }
            return "  " + s.paint("Today       ", Theme.mist) + parts.joined(separator: " · ")
        }
        let night = report.hourly.filter { $0.time > ctx.now && $0.time < ctx.now.addingTimeInterval(14 * 3600) }
        let chance = night.compactMap(\.precipitationProbability).max()
        var parts = ["Low \(fmt.temperature(report.overnightLow(after: ctx.now)))"]
        if let code = mostSevere(night.compactMap(\.weatherCode)) { parts.append(WeatherCondition.description(code)) }
        if let chance, chance >= 20 { parts.append("\(Int(chance))% chance of rain") }
        return "  " + s.paint("Tonight     ", Theme.mist) + parts.joined(separator: " · ")
    }

    static func mostSevere(_ codes: [Int]) -> Int? {
        codes.max { severity($0) < severity($1) }
    }

    static func severity(_ code: Int) -> Int {
        switch code {
        case 95...99: 6
        case 71...86: 5
        case 61...67: 4
        case 51...57: 3
        case 45, 48: 2
        case 3: 1
        default: 0
        }
    }

    // MARK: Plain

    static func plain(place: Place, weather: Fetched<WeatherReport>, alerts: Fetched<[WeatherAlert]>,
                      lightning: Fetched<LightningSnapshot>?, nowcast: Nowcast?, ctx: Context) -> [String] {
        let report = weather.value
        let fmt = Formatter(units: ctx.units, timeZone: report?.timeZone ?? .current)
        var lines = ["\(place.name)."]
        if let c = report?.current {
            lines.append("Now: \(fmt.temperature(c.temperature, unit: true)), \(WeatherCondition.description(c.weatherCode).lowercased()). Feels like \(fmt.temperature(c.apparentTemperature, unit: true)). Humidity \(fmt.percent(c.humidity)).")
            lines.append("Wind: \(fmt.wind(speed: c.windSpeed, gust: c.windGusts, direction: c.windDirection)).")
        } else {
            lines.append("Current conditions are unavailable: \(weather.error ?? "unknown error").")
        }
        if let list = alerts.value {
            if list.isEmpty {
                lines.append("Alerts: none active for this location.")
            } else {
                for alert in list {
                    var line = "Alert: \(alert.event)"
                    if let end = alert.endsOrExpires { line += " until \(fmt.until(end, now: ctx.now)) \(fmt.zoneAbbreviation(end))" }
                    if let sender = alert.sender { line += ", from \(sender)" }
                    lines.append(line + ".")
                    if let instruction = alert.instruction.flatMap(firstSentence) { lines.append("  " + instruction) }
                }
            }
        } else if place.isUnitedStates {
            lines.append("Alerts: unavailable (\(alerts.error ?? "unknown error")). This is not an all-clear.")
        }
        if let nowcast {
            lines.append("Rain: " + TextWidth.strippingANSI(nowcastSummary(nowcast, fmt: fmt, ctx: ctx)) + ".")
        }
        if let report {
            let days = DayRows.upcoming(report, from: ctx.now, count: 5)
            if !days.isEmpty { lines.append(contentsOf: ["Next 5 days:"] + DayRows.plain(days, fmt: fmt)) }
        }
        if let lightning {
            lines.append(TextWidth.strippingANSI(lightningLine(lightning, fmt: fmt, ctx: ctx)).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "Lightning   ", with: "Lightning: ") + ".")
        }
        if let stored = weather.storedAt {
            lines.append("Sources: Open-Meteo\(place.isUnitedStates ? ", NWS" : "")\(lightning != nil ? ", Xweather" : ""). Updated \(Formatter.ago(stored, now: ctx.now)).")
        }
        return lines
    }
}

// MARK: JSON

struct NowJSON: Encodable {
    let schema = "dreadcast.now/1"
    let generatedAt: Date
    let location: LocationJSON
    let conditions: ConditionsJSON?
    let alerts: [AlertJSON]?
    let alertsError: String?
    let nowcast: NowcastSummaryJSON?
    let lightning: LightningJSON?
    let days: [ForecastJSON.Day]
    let stale: [String]

    init(place: Place, weather: Fetched<WeatherReport>, alerts: Fetched<[WeatherAlert]>,
         lightning: Fetched<LightningSnapshot>?, nowcast: Nowcast?, now: Date) {
        generatedAt = now
        location = LocationJSON(place)
        conditions = weather.value.map { ConditionsJSON($0, storedAt: weather.storedAt ?? now) }
        self.alerts = alerts.value.map { $0.map(AlertJSON.init) }
        alertsError = alerts.value == nil ? alerts.error : nil
        self.nowcast = nowcast.map(NowcastSummaryJSON.init)
        self.lightning = lightning?.value.map { LightningJSON($0, now: now) }
        days = weather.value.map { ForecastJSON.days(DayRows.upcoming($0, from: now, count: 5), timeZone: $0.timeZone) } ?? []
        var stale: [String] = []
        if weather.isStale { stale.append("conditions") }
        if alerts.isStale { stale.append("alerts") }
        if lightning?.isStale == true { stale.append("lightning") }
        self.stale = stale
    }
}

struct LocationJSON: Encodable {
    let name: String
    let latitude: Double
    let longitude: Double
    let source: String

    init(_ place: Place) {
        name = place.name
        latitude = place.coordinate.latitude
        longitude = place.coordinate.longitude
        source = place.source.rawValue
    }
}

struct ConditionsJSON: Encodable {
    let source = "open-meteo"
    let observedAt: Date
    let fetchedAt: Date
    let units: String
    let temperature: Double?
    let feelsLike: Double?
    let humidity: Double?
    let dewPoint: Double?
    let condition: String
    let weatherCode: Int?
    let windSpeed: Double?
    let windGusts: Double?
    let windDirection: Double?
    let pressure: Double?

    init(_ report: WeatherReport, storedAt: Date) {
        let c = report.current
        observedAt = c.time
        fetchedAt = storedAt
        units = report.units.rawValue
        temperature = c.temperature
        feelsLike = c.apparentTemperature
        humidity = c.humidity
        dewPoint = c.dewPoint
        condition = WeatherCondition.description(c.weatherCode)
        weatherCode = c.weatherCode
        windSpeed = c.windSpeed
        windGusts = c.windGusts
        windDirection = c.windDirection
        pressure = c.pressure
    }
}

struct AlertJSON: Encodable {
    let id: String
    let event: String
    let level: String
    let severity: String
    let urgency: String?
    let headline: String
    let area: String
    let sender: String?
    let effective: Date?
    let onset: Date?
    let expires: Date?
    let ends: Date?
    let description: String
    let instruction: String?

    init(_ alert: WeatherAlert) {
        id = alert.id
        event = alert.event
        level = alert.level.rawValue
        severity = alert.severity.rawValue
        urgency = alert.urgency
        headline = alert.headline
        area = alert.areaDescription
        sender = alert.sender
        effective = alert.effective
        onset = alert.onset
        expires = alert.expires
        ends = alert.ends
        description = alert.description
        instruction = alert.instruction
    }
}

struct NowcastSummaryJSON: Encodable {
    let source = "rainviewer"
    let latestFrame: Date?
    let raining: Bool
    let arrivalMinutes: Int?
    let endMinutes: Int?
    let heavyMinutes: Int
    let peakDBZ: Double?
    let motionBearing: Double?
    let motionMPH: Double?
    let confidence: String

    init(_ n: Nowcast) {
        latestFrame = n.latestFrame
        raining = n.isRainingNow
        arrivalMinutes = n.arrivalMinutes
        endMinutes = n.endMinutes
        heavyMinutes = n.heavyMinutes
        peakDBZ = n.peakDBZ
        motionBearing = n.motionBearing
        motionMPH = n.motionMPH
        confidence = n.confidence.rawValue
    }
}

struct LightningJSON: Encodable {
    let source = "xweather"
    let radiusMiles: Double
    let strikes20m: Int
    let nearestMiles: Double?
    let nearestBearing: String?
    let nearestAgeSeconds: Int?

    init(_ snapshot: LightningSnapshot, now: Date) {
        radiusMiles = snapshot.radiusMiles
        strikes20m = snapshot.current(at: now).count
        let nearest = snapshot.nearest(at: now)
        nearestMiles = nearest.map { ($0.miles * 10).rounded() / 10 }
        nearestBearing = nearest.map { Compass.point(snapshot.center.bearingDegrees(to: $0.strike.coordinate)) }
        nearestAgeSeconds = nearest.map { Int(now.timeIntervalSince($0.strike.timestamp)) }
    }
}
