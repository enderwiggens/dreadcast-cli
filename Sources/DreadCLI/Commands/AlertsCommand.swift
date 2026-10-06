import Foundation
import DreadcastKit
import DreadTerminal

/// `dread alerts`: active NWS products in full, a change stream, and exit codes for scripts.
enum AlertsCommand {
    enum Threshold {
        case severity(WeatherAlert.Severity)
        case level(WeatherAlert.Level)

        init?(_ text: String) {
            switch text.lowercased() {
            case "minor": self = .severity(.minor)
            case "moderate": self = .severity(.moderate)
            case "severe": self = .severity(.severe)
            case "extreme": self = .severity(.extreme)
            case "advisory": self = .level(.advisory)
            case "watch": self = .level(.watch)
            case "warning": self = .level(.warning)
            case "any", "all": self = .severity(.unknown)
            default: return nil
            }
        }

        func matches(_ alert: WeatherAlert) -> Bool {
            switch self {
            case .severity(let minimum): return alert.severity >= minimum
            case .level(let minimum): return alert.level >= minimum
            }
        }
    }

    static func run(_ ctx: Context) async throws -> ExitCode {
        var threshold: Threshold?
        if let value = ctx.arguments.value("fail-on") {
            guard let parsed = Threshold(value) else {
                return ctx.fail("--fail-on takes minor, moderate, severe, extreme, advisory, watch or warning.", code: .usage)
            }
            threshold = parsed
        }
        if ctx.arguments.has("all") {
            let places = ctx.config.places
            guard !places.isEmpty else {
                return ctx.fail("No saved places. Run `dread setup` or `dread places add <place>`.", code: .setupRequired)
            }
            if ctx.arguments.has("follow") { return await follow(ctx, places: places, named: true) }
            return await all(ctx, places: places, threshold: threshold)
        }
        let place = try await ctx.resolveLocation()
        if ctx.arguments.has("follow") { return await follow(ctx, places: [SavedPlace(name: "", place: place)], named: false) }

        let fetched = await ctx.alerts(place)
        guard let alerts = fetched.value else {
            return ctx.fail("Alerts are unavailable: \(fetched.error ?? "unknown error"). This is not an all-clear.", code: .unavailable)
        }
        let fmt = Formatter(units: ctx.units, timeZone: ctx.timeZone(for: place))

        switch ctx.mode {
        case .json:
            ctx.writeJSON(AlertsJSON(place: place, alerts: alerts, fetchedAt: fetched.storedAt ?? ctx.now, stale: fetched.isStale))
        case .plain:
            if alerts.isEmpty {
                ctx.write("No active alerts for \(place.name).")
            } else {
                ctx.write(alerts.flatMap { plainLines($0, fmt: fmt, now: ctx.now) + [""] })
            }
        case .pretty:
            ctx.write(prettyLines(alerts, place: place, fetched: fetched, fmt: fmt, ctx: ctx))
        }

        if let threshold, alerts.contains(where: threshold.matches) {
            if ctx.mode != .json {
                let worst = alerts.filter(threshold.matches).sorted(by: WeatherAlert.threatOrder)[0]
                var message = "\(worst.event)"
                if let end = worst.endsOrExpires { message += " until \(fmt.until(end, now: ctx.now)) \(fmt.zoneAbbreviation(end))" }
                if let sender = worst.sender { message += " (\(sender))" }
                Console.writeError(ctx.styler.paint("dread: ", Theme.faint) + ctx.styler.paint(message, NowCommand.alertColor(worst)) + ". Exit 1.\n")
            }
            return .alertActive
        }
        return fetched.isStale ? .unavailable : .ok
    }

    static func prettyLines(_ alerts: [WeatherAlert], place: Place, fetched: Fetched<[WeatherAlert]>, fmt: Formatter, ctx: Context,
                            width requested: Int? = nil) -> [String] {
        let s = ctx.styler
        let width = requested ?? min(max(ctx.terminal.columns - 2, 60), 96)
        var lines = [""]
        let updated = fetched.storedAt.map { (fetched.isStale ? "stale · " : "") + "updated " + Formatter.ago($0, now: ctx.now) } ?? ""
        lines.append(TextWidth.spread(ctx.title("ALERTS", place: place),
                                      s.paint("NWS · " + updated, fetched.isStale ? Theme.advisory : Theme.faint), width: width))
        lines.append("")
        if alerts.isEmpty {
            lines.append("  " + s.paint("No active watches, warnings or advisories for this location.", Theme.mint))
            lines.append("")
            return lines
        }
        for alert in alerts {
            lines.append(contentsOf: NowCommand.alertLines(alert, fmt: fmt, ctx: ctx, width: width).prefix(1))
            lines.append("    " + s.paint(TextWidth.truncate(alert.areaDescription, to: width - 4), Theme.faint))
            var timing: [String] = []
            if let onset = alert.onset ?? alert.effective { timing.append("from \(fmt.until(onset, now: ctx.now))") }
            if let ends = alert.endsOrExpires { timing.append("until \(fmt.until(ends, now: ctx.now)) \(fmt.zoneAbbreviation(ends))") }
            timing.append("severity \(alert.severity.rawValue)")
            if let urgency = alert.urgency { timing.append("urgency \(urgency.lowercased())") }
            lines.append("    " + s.paint(timing.joined(separator: " · "), Theme.mist))
            lines.append("")
            for paragraph in alert.description.components(separatedBy: "\n\n") where !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for line in TextWidth.wrap(paragraph.replacingOccurrences(of: "\n", with: " "), width: width - 4) {
                    lines.append("    " + line)
                }
                lines.append("")
            }
            if let instruction = alert.instruction, !instruction.isEmpty {
                lines.append("    " + s.paint("What to do", Theme.porcelain, bold: true))
                for line in TextWidth.wrap(instruction.replacingOccurrences(of: "\n", with: " "), width: width - 4) {
                    lines.append("    " + line)
                }
                lines.append("")
            }
        }
        return lines
    }

    static func plainLines(_ alert: WeatherAlert, fmt: Formatter, now: Date) -> [String] {
        var lines = [alert.event + (alert.endsOrExpires.map { " until \(fmt.until($0, now: now)) \(fmt.zoneAbbreviation($0))" } ?? "") + "."]
        lines.append("Area: \(alert.areaDescription).")
        if let sender = alert.sender { lines.append("Issued by \(sender).") }
        lines.append(alert.description.replacingOccurrences(of: "\n", with: " "))
        if let instruction = alert.instruction { lines.append("What to do: " + instruction.replacingOccurrences(of: "\n", with: " ")) }
        return lines
    }

    /// `dread alerts --all`: every saved place, one section each. `--fail-on` exits 1 when
    /// any place has an alert at or above the level.
    static func all(_ ctx: Context, places: [SavedPlace], threshold: Threshold?) async -> ExitCode {
        let results = await fetchAll(ctx, places: places)
        switch ctx.mode {
        case .json:
            ctx.writeJSON(AlertsAllJSON(results, now: ctx.now))
        case .plain:
            for (saved, fetched) in results {
                let label = "\(saved.name) (\(saved.place.name))"
                guard let fetched else { ctx.write("\(label): NWS alerts cover the United States and its territories.\n"); continue }
                guard let alerts = fetched.value else { ctx.write("\(label): alerts unavailable: \(fetched.error ?? "unknown error"). This is not an all-clear.\n"); continue }
                let fmt = Formatter(units: ctx.units, timeZone: ctx.timeZone(for: saved.place))
                ctx.write(alerts.isEmpty ? ["\(label): no active alerts.", ""] : ["\(label):"] + alerts.flatMap { plainLines($0, fmt: fmt, now: ctx.now) + [""] })
            }
        case .pretty:
            let s = ctx.styler
            for (saved, fetched) in results {
                var shown = saved.place
                shown.name = "\(saved.name) · \(saved.place.name)"
                guard let fetched else {
                    ctx.write(["", ctx.title("ALERTS", place: shown), "", "  " + s.paint("NWS alerts cover the United States and its territories.", Theme.faint)])
                    continue
                }
                guard let alerts = fetched.value else {
                    ctx.write(["", ctx.title("ALERTS", place: shown), "",
                               "  " + s.paint("Alerts are unavailable: \(fetched.error ?? "unknown error"). This is not an all-clear.", Theme.advisory)])
                    continue
                }
                let fmt = Formatter(units: ctx.units, timeZone: ctx.timeZone(for: saved.place))
                ctx.write(prettyLines(alerts.sorted(by: WeatherAlert.threatOrder), place: shown, fetched: fetched, fmt: fmt, ctx: ctx).dropLast())
            }
            ctx.write("")
        }

        if let threshold {
            let matches = results.flatMap { saved, fetched in (fetched?.value ?? []).filter(threshold.matches).map { (saved, $0) } }
            if let (saved, worst) = matches.sorted(by: { WeatherAlert.threatOrder($0.1, $1.1) }).first {
                if ctx.mode != .json {
                    let fmt = Formatter(units: ctx.units, timeZone: ctx.timeZone(for: saved.place))
                    var message = "\(worst.event) at \(saved.name) (\(saved.place.name))"
                    if let end = worst.endsOrExpires { message += " until \(fmt.until(end, now: ctx.now)) \(fmt.zoneAbbreviation(end))" }
                    Console.writeError(ctx.styler.paint("dread: ", Theme.faint) + ctx.styler.paint(message, NowCommand.alertColor(worst)) + ". Exit 1.\n")
                }
                return .alertActive
            }
        }
        let incomplete = results.contains { $0.1.map { $0.value == nil || $0.isStale } ?? false }
        return incomplete ? .unavailable : .ok
    }

    /// Alerts for each place, fetched together; nil where the NWS doesn't cover it.
    static func fetchAll(_ ctx: Context, places: [SavedPlace]) async -> [(SavedPlace, Fetched<[WeatherAlert]>?)] {
        await withTaskGroup(of: (Int, Fetched<[WeatherAlert]>?).self) { group in
            for (i, saved) in places.enumerated() {
                group.addTask { (i, saved.place.isUnitedStates ? await ctx.alerts(saved.place) : nil) }
            }
            var fetched = [Fetched<[WeatherAlert]>?](repeating: nil, count: places.count)
            for await (i, value) in group { fetched[i] = value }
            return Array(zip(places, fetched))
        }
    }

    /// Prints new, changed and ended alerts every two minutes until interrupted. With
    /// several places, each line names its place.
    static func follow(_ ctx: Context, places: [SavedPlace], named: Bool) async -> ExitCode {
        var known: [Int: [String: WeatherAlert]] = [:]
        var announcedClear = false
        let s = ctx.styler
        let watched = places.filter { !named || $0.place.isUnitedStates }
        if ctx.mode == .pretty {
            let what = named ? "your \(watched.count) US place\(watched.count == 1 ? "" : "s")" : places[0].place.name
            ctx.write("  " + s.paint("Following NWS alerts for \(what). Ctrl-C stops.", Theme.faint))
            for saved in places where named && !saved.place.isUnitedStates {
                ctx.write("  " + s.paint("Skipping \(saved.name): NWS alerts cover the United States and its territories.", Theme.faint))
            }
        }
        while true {
            ctx.refreshClock()
            let results = await fetchAll(ctx, places: watched)
            var clear = true
            for (i, (saved, result)) in results.enumerated() {
                let fmt = Formatter(units: ctx.units, timeZone: ctx.timeZone(for: saved.place))
                let fetched = result ?? .failure("NWS alerts cover the United States and its territories.")
                let name = named ? saved.name : nil
                guard let alerts = fetched.value else {
                    if ctx.mode == .json {
                        struct Problem: Encodable { let type = "unavailable"; let place: String?; let error: String; let at: Date }
                        ctx.writeJSON(Problem(place: name, error: fetched.error ?? "unknown error", at: ctx.now))
                    } else {
                        ctx.write("  " + s.paint("\(fmt.time(ctx.now))  " + (name.map { "\($0): " } ?? "") + "Alerts unavailable: \(fetched.error ?? "unknown error"). Retrying.", Theme.advisory))
                    }
                    clear = false
                    continue
                }
                let first = known[i] == nil
                let previous = known[i] ?? [:]
                var current: [String: WeatherAlert] = [:]
                for alert in alerts { current[alert.id] = alert }
                for alert in alerts where previous[alert.id] == nil {
                    emit(kind: first ? "active" : "new", alert: alert, place: name, ctx: ctx, fmt: fmt)
                }
                for (id, alert) in previous where current[id] == nil {
                    emit(kind: "ended", alert: alert, place: name, ctx: ctx, fmt: fmt)
                }
                if !alerts.isEmpty { clear = false }
                known[i] = current
            }
            // Said once, after the first round in which every place answered with nothing.
            if clear, !announcedClear, ctx.mode == .pretty, known.count == results.count {
                ctx.write("  " + s.paint(named ? "No active alerts at any of your places right now." : "No active alerts right now.", Theme.mint))
                announcedClear = true
            }
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
        }
    }

    static func emit(kind: String, alert: WeatherAlert, place: String? = nil, ctx: Context, fmt: Formatter) {
        switch ctx.mode {
        case .json:
            struct Event: Encodable { let type: String; let at: Date; let place: String?; let alert: AlertJSON }
            let encoder = JSONEncoder.dreadcast
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(Event(type: kind, at: ctx.now, place: place, alert: AlertJSON(alert))), let text = String(data: data, encoding: .utf8) {
                Console.write(text + "\n")
            }
        case .plain:
            ctx.write("\(fmt.time(ctx.now)) \(kind): " + (place.map { "\($0): " } ?? "") + alert.event
                      + (alert.endsOrExpires.map { " until \(fmt.until($0, now: ctx.now))" } ?? ""))
        case .pretty:
            let s = ctx.styler
            let color = kind == "ended" ? Theme.faint : NowCommand.alertColor(alert)
            ctx.write("  " + s.paint(fmt.time(ctx.now), Theme.faint) + "  " + s.paint(kind.uppercased(), color, bold: true) + "  "
                      + (place.map { s.paint($0, Theme.porcelain, bold: true) + s.paint(" · ", Theme.faint) } ?? "") + alert.event
                      + (alert.endsOrExpires.map { s.paint("  until \(fmt.until($0, now: ctx.now))", Theme.mist) } ?? ""))
        }
    }
}

struct AlertsAllJSON: Encodable {
    struct Entry: Encodable {
        let name: String
        let location: LocationJSON
        let fetchedAt: Date?
        let stale: Bool
        let alerts: [AlertJSON]?
        let error: String?
    }
    let schema = "dreadcast.alerts-all/1"
    let source = "nws"
    let generatedAt: Date
    let places: [Entry]

    init(_ results: [(SavedPlace, Fetched<[WeatherAlert]>?)], now: Date) {
        generatedAt = now
        places = results.map { saved, fetched in
            Entry(name: saved.name, location: LocationJSON(saved.place), fetchedAt: fetched?.storedAt, stale: fetched?.isStale ?? false,
                  alerts: fetched?.value.map { $0.sorted(by: WeatherAlert.threatOrder).map(AlertJSON.init) },
                  error: fetched == nil ? "NWS alerts cover the United States and its territories." : fetched?.value == nil ? fetched?.error ?? "unknown error" : nil)
        }
    }
}

struct AlertsJSON: Encodable {
    let schema = "dreadcast.alerts/1"
    let location: LocationJSON
    let source = "nws"
    let fetchedAt: Date
    let stale: Bool
    let alerts: [AlertJSON]

    init(place: Place, alerts: [WeatherAlert], fetchedAt: Date, stale: Bool) {
        location = LocationJSON(place)
        self.fetchedAt = fetchedAt
        self.stale = stale
        self.alerts = alerts.map(AlertJSON.init)
    }
}
