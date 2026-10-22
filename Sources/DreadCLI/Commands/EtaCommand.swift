import Foundation
import DreadcastKit
import DreadTerminal

/// `dread eta`: when rain reaches you, from recent radar motion, or where no radar
/// reaches, from the forecast model.
enum EtaCommand {
    static func run(_ ctx: Context) async throws -> ExitCode {
        let place = try await ctx.resolveLocation()
        let fetched = await ctx.nowcast(place)
        if fetched.outsideCoverage { return await model(ctx, place: place) }
        guard let nowcast = fetched.value else {
            return ctx.fail("Radar timing is unavailable: \(fetched.error ?? "unknown error").", code: .unavailable)
        }
        let fmt = Formatter(units: ctx.units, timeZone: ctx.timeZone(for: place))
        switch ctx.mode {
        case .json:
            ctx.writeJSON(EtaJSON(place: place, nowcast: nowcast, stale: fetched.isStale))
        case .plain:
            ctx.write([headline(nowcast, fmt: fmt, ctx: ctx, styled: false), motionLine(nowcast, fmt: fmt),
                       "Confidence: \(nowcast.confidence.rawValue). Radar: \(nowcast.radarCredit), \(nowcast.frameTimes.count) frames."])
        case .pretty:
            ctx.write(pretty(place: place, nowcast: nowcast, fetched: fetched, fmt: fmt, ctx: ctx))
        }
        return fetched.isStale ? .unavailable : .ok
    }

    static func intensity(_ dbz: Double) -> String { RainRate.Intensity(dbz: dbz).label }

    static func headline(_ n: Nowcast, fmt: Formatter, ctx: Context, styled: Bool) -> String {
        let s = styled ? ctx.styler : Styler(mode: .none)
        if n.isRainingNow {
            let now = intensity(n.currentDBZ ?? 0)
            if let end = n.endMinutes {
                return "Rain is falling now (\(now)). It should ease in " + s.paint("~\(Formatter.duration(minutes: end))", ctx.highlight, bold: true)
                    + " (\(fmt.time(ctx.now.addingTimeInterval(Double(end) * 60))))."
            }
            return "Rain is falling now (\(now)) and should continue for at least 2 hours."
        }
        if let arrival = n.arrivalMinutes {
            var text = "Rain reaches you in " + s.paint("~\(Formatter.duration(minutes: arrival))", ctx.highlight, bold: true)
                + " (\(fmt.time(ctx.now.addingTimeInterval(Double(arrival) * 60))))."
            if n.heavyMinutes > 0 { text += " Heavy for ~\(n.heavyMinutes) min." }
            else if let peak = n.peakDBZ { text += " Mostly \(intensity(peak))." }
            if let end = n.endMinutes { text += " Easing by \(fmt.time(ctx.now.addingTimeInterval(Double(end) * 60)))." }
            return text
        }
        if let miles = n.nearestEchoMiles, let bearing = n.nearestEchoBearing {
            return "No rain expected in the next 2 hours. Nearest rain: \(fmt.distance(miles: miles)) \(Compass.point(bearing))."
        }
        return "No rain within \(fmt.distance(miles: Context.nowcastRangeMiles)) and none expected in the next 2 hours."
    }

    static func motionLine(_ n: Nowcast, fmt: Formatter) -> String {
        guard let mph = n.motionMPH else { return "Echo motion couldn’t be measured; too little rain nearby." }
        guard let bearing = n.motionBearing else { return "Echoes are nearly stationary." }
        return "Echoes are moving \(Compass.word(bearing)) at \(fmt.speed(mph: mph)); trend \(n.trend.rawValue)."
    }

    static func pretty(place: Place, nowcast n: Nowcast, fetched: Fetched<Nowcast>, fmt: Formatter, ctx: Context) -> [String] {
        let s = ctx.styler
        let width = min(max(ctx.terminal.columns - 2, 60), 100)
        var lines = [""]
        lines.append(TextWidth.spread("  " + s.paint("RAIN ETA", Theme.porcelain, bold: true) + s.paint("  ·  ", Theme.faint) + place.name,
                                      s.paint(n.radarName.uppercased() + (fetched.isStale ? " · stale" : ""), fetched.isStale ? Theme.advisory : Theme.faint), width: width))
        lines.append("")
        lines.append("  " + headline(n, fmt: fmt, ctx: ctx, styled: true))
        lines.append("")

        lines += chart(n.steps.prefix(60).map(\.dbz), ctx: ctx)
        lines.append("")

        let label = { (text: String) in "  " + s.paint(TextWidth.pad(text, to: 12), Theme.mist) }
        lines.append(label("Motion") + motionLine(n, fmt: fmt))
        lines.append(label("Radar") + n.radarCredit)
        if let first = n.frameTimes.first, let last = n.frameTimes.last {
            lines.append(label("Frames") + "\(fmt.time(first))–\(fmt.time(last))" + s.paint("  (\(n.frameTimes.count) frames, about \(max(1, Int((last.timeIntervalSince(first) / Double(max(1, n.frameTimes.count - 1)) / 60).rounded()))) min apart)", Theme.faint))
        }
        let confidenceColor: RGB = n.confidence == .high ? Theme.mint : n.confidence == .medium ? Theme.advisory : Theme.warning
        var reasons: [String] = []
        if n.motionMPH == nil { reasons.append("too little rain to track") }
        if n.trend != .steady { reasons.append("echoes are \(n.trend.rawValue)") }
        if let arrival = n.arrivalMinutes, arrival > 60 { reasons.append("arrival is more than an hour out") }
        lines.append(label("Confidence") + s.paint(n.confidence.rawValue, confidenceColor) + (reasons.isEmpty ? "" : s.paint(" · " + reasons.joined(separator: ", "), Theme.faint)))

        if !n.cells.isEmpty {
            lines.append("")
            lines.append("  " + s.bold("STRONG CELLS") + s.paint("   ≥ 40 dBZ within \(fmt.distance(miles: Context.nowcastRangeMiles))", Theme.faint))
            for cell in n.cells.prefix(3) {
                var text = "  " + s.paint(TextWidth.pad("\(fmt.distance(miles: cell.distanceMiles)) \(Compass.point(cell.bearing))", to: 12), Theme.porcelain)
                    + s.paint(TextWidth.pad("\(Int(cell.maxDBZ)) dBZ", to: 9), Theme.lightning[cell.maxDBZ >= 50 ? 2 : 1])
                if let arrival = cell.arrivalMinutes {
                    text += "arrives in ~\(Formatter.duration(minutes: arrival))"
                } else if let miss = cell.closestApproachMiles, let minutes = cell.closestApproachMinutes {
                    text += "passes \(fmt.distance(miles: miss)) away in ~\(Formatter.duration(minutes: minutes))"
                } else {
                    text += s.paint("moving away", Theme.faint)
                }
                lines.append(text)
            }
        }
        lines.append("")
        for line in TextWidth.wrap("Timing guidance only, not a rainfall total. Storms that form or fade along the way aren’t foreseen.", width: width - 2) {
            lines.append("  " + s.paint(line, Theme.faint))
        }
        lines.append("")
        return lines
    }

    /// Two hours in three rows (heavy, moderate, light), one column per two minutes,
    /// from reflectivity; nil where there's no value.
    static func chart(_ values: [Double?], ctx: Context) -> [String] {
        let s = ctx.styler
        var lines: [String] = []
        let labels = ["heavy ", "mod   ", "light "]
        for row in stride(from: 2, through: 0, by: -1) {
            var line = "  " + s.paint(labels[2 - row], Theme.mist) + s.paint("│", Theme.faint)
            for value in values {
                guard let dbz = value else { line += row == 0 ? s.paint("·", Theme.faint) : " "; continue }
                let fraction = max(0, min(1, (dbz - 15) / 40))
                let character = Charts.block(fraction, row: row, of: 3)
                let color: RGB = dbz >= 40 ? Theme.lightning[2] : dbz >= 30 ? Theme.lightning[1] : dbz >= 20 ? Theme.rain : Theme.faint
                line += character == " " ? " " : s.paint(String(character), color)
            }
            lines.append(line)
        }
        var axis = "└"
        for i in 0..<values.count { axis += i % 10 == 0 ? "┬" : "─" }
        lines.append("  " + String(repeating: " ", count: 6) + s.paint(axis, Theme.faint))
        let marks = ["now", "+20m", "+40m", "+60m", "+80m", "+100m"].map { TextWidth.pad($0, to: 10) }.joined()
        lines.append("  " + String(repeating: " ", count: 7) + s.paint(marks.trimmingCharacters(in: .whitespaces), Theme.faint))
        return lines
    }

    // MARK: Where no radar reaches

    /// Timing from the forecast model's 15-minute precipitation, labeled as such: it
    /// has the model's resolution and can't see rain moving.
    static func model(_ ctx: Context, place: Place) async -> ExitCode {
        let weather = await ctx.weather(place)
        guard let report = weather.value else {
            return ctx.fail("No radar reaches \(place.name), and the forecast is unavailable: \(weather.error ?? "unknown error").", code: .unavailable)
        }
        guard let model = ModelRain(report: report, now: ctx.now) else {
            return ctx.fail("No radar reaches \(place.name), and the forecast has no 15-minute steps for the next two hours.", code: .unavailable)
        }
        let fmt = Formatter(units: ctx.units, timeZone: report.timeZone)
        switch ctx.mode {
        case .json:
            ctx.writeJSON(EtaJSON(place: place, model: model, stale: weather.isStale))
        case .plain:
            ctx.write([modelHeadline(model, fmt: fmt, ctx: ctx, styled: false), modelNote(place)])
        case .pretty:
            ctx.write(modelPretty(place: place, model: model, stale: weather.isStale, fmt: fmt, ctx: ctx))
        }
        return weather.isStale ? .unavailable : .ok
    }

    static func modelHeadline(_ model: ModelRain, fmt: Formatter, ctx: Context, styled: Bool) -> String {
        let s = styled ? ctx.styler : Styler(mode: .none)
        // An old reading's steps can end before two hours are up.
        let span = model.coversTwoHours ? "the next 2 hours" : "until ~\(fmt.time(model.until))"
        if model.rainingNow {
            if let end = model.end {
                return "The forecast model has rain falling now, easing by " + s.paint("~\(fmt.time(end))", ctx.highlight, bold: true) + "."
            }
            return model.coversTwoHours ? "The forecast model has rain falling now and for at least the next 2 hours."
                : "The forecast model has rain falling now and \(span)."
        }
        guard let arrival = model.arrival, let minutes = model.arrivalMinutes else {
            return model.coversTwoHours ? "The forecast model expects no rain in the next 2 hours."
                : "The forecast model expects no rain \(span)."
        }
        var text = "The forecast model expects rain from " + s.paint("~\(fmt.time(arrival))", ctx.highlight, bold: true)
            + " (in ~\(Formatter.duration(minutes: minutes)))."
        if model.heavyMinutes > 0 { text += " Heavy for ~\(model.heavyMinutes) min." }
        if let end = model.end { text += " Easing by \(fmt.time(end))." }
        return text
    }

    static func modelNote(_ place: Place) -> String {
        "No radar reaches \(place.name), so this timing is the forecast model’s, in 15-minute steps. \(Context.radarCoverage)"
    }

    static func modelPretty(place: Place, model: ModelRain, stale: Bool, fmt: Formatter, ctx: Context) -> [String] {
        let s = ctx.styler
        let width = min(max(ctx.terminal.columns - 2, 60), 100)
        var lines = [""]
        lines.append(TextWidth.spread("  " + s.paint("RAIN ETA", Theme.porcelain, bold: true) + s.paint("  ·  ", Theme.faint) + place.name,
                                      s.paint("FORECAST MODEL" + (stale ? " · stale" : ""), stale ? Theme.advisory : Theme.faint), width: width))
        lines.append("")
        lines.append("  " + modelHeadline(model, fmt: fmt, ctx: ctx, styled: true))
        lines.append("")
        lines += chart((0..<60).map { model.equivalentDBZ(atMinute: $0 * 2) }, ctx: ctx)
        lines.append("")
        lines.append("  " + s.paint(TextWidth.pad("Source", to: 12), Theme.mist) + "Open-Meteo forecast model, 15-minute steps")
        lines.append("")
        for line in TextWidth.wrap(modelNote(place) + " Timing guidance only, not a rainfall total.", width: width - 2) {
            lines.append("  " + s.paint(line, Theme.faint))
        }
        lines.append("")
        return lines
    }
}

struct EtaJSON: Encodable {
    struct Step: Encodable {
        let minutes: Int
        let dbz: Double?
        /// The model's 15-minute total, in `units`; radar steps leave it out.
        var precipitation: Double?
    }
    let schema = "dreadcast.eta/1"
    let location: LocationJSON
    /// `dreadcast` (the Dreadcast API's radar) or `model` (the forecast, where no radar
    /// reaches). The model has no frames, reflectivity, motion, trend or cells.
    let source: String
    /// Whom to credit, such as "Dreadcast Radar" or "Dreadcast Radar · EUMETNET OPERA (CC BY 4.0), modified".
    let credit: String
    let method: String
    /// The model's precipitation units, `imperial` (inches) or `metric` (millimeters).
    var units: String?
    let generatedAt: Date
    let frames: [Date]
    let raining: Bool
    let currentDBZ: Double?
    let arrivalMinutes: Int?
    let endMinutes: Int?
    let heavyMinutes: Int
    let peakDBZ: Double?
    let motionBearing: Double?
    let motionMPH: Double?
    let trend: String?
    let confidence: String
    let steps: [Step]
    let stormCells: [StormCellJSON]
    let stale: Bool

    init(place: Place, nowcast n: Nowcast, stale: Bool) {
        location = LocationJSON(place)
        source = n.radarSourceID
        credit = n.radarCredit
        method = "cross-correlation motion, backward trace through the latest frame"
        generatedAt = n.generatedAt
        frames = n.frameTimes
        raining = n.isRainingNow
        currentDBZ = n.currentDBZ
        arrivalMinutes = n.arrivalMinutes
        endMinutes = n.endMinutes
        heavyMinutes = n.heavyMinutes
        peakDBZ = n.peakDBZ
        motionBearing = n.motionBearing.map { $0.rounded() }
        motionMPH = n.motionMPH.map { ($0 * 10).rounded() / 10 }
        trend = n.trend.rawValue
        confidence = n.confidence.rawValue
        steps = n.steps.map { Step(minutes: $0.minutes, dbz: $0.dbz.flatMap { $0 > -32 ? $0 : nil }) }
        stormCells = n.cells.map(StormCellJSON.init)
        self.stale = stale
    }

    /// Where no radar reaches. The model's timing is always low confidence.
    init(place: Place, model: ModelRain, stale: Bool) {
        location = LocationJSON(place)
        source = "model"
        credit = "Open-Meteo"
        method = "forecast model, 15-minute precipitation"
        units = model.units.rawValue
        generatedAt = model.now
        frames = []
        raining = model.rainingNow
        currentDBZ = nil
        arrivalMinutes = model.arrivalMinutes
        endMinutes = model.endMinutes
        heavyMinutes = model.heavyMinutes
        peakDBZ = nil
        motionBearing = nil
        motionMPH = nil
        trend = nil
        confidence = Nowcast.Confidence.low.rawValue
        steps = model.steps.map { Step(minutes: model.minutes(until: $0.start), dbz: nil, precipitation: $0.precipitation) }
        stormCells = []
        self.stale = stale
    }
}
