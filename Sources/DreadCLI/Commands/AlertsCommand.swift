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
        let place = try await ctx.resolveLocation()
        var threshold: Threshold?
        if let value = ctx.arguments.value("fail-on") {
            guard let parsed = Threshold(value) else {
                return ctx.fail("--fail-on takes minor, moderate, severe, extreme, advisory, watch or warning.", code: .usage)
            }
            threshold = parsed
        }
        if ctx.arguments.has("follow") { return await follow(ctx, place: place) }

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

    /// Prints new, changed and ended alerts every two minutes until interrupted.
    static func follow(_ ctx: Context, place: Place) async -> ExitCode {
        var known: [String: WeatherAlert] = [:]
        var first = true
        let fmt = Formatter(units: ctx.units, timeZone: ctx.timeZone(for: place))
        let s = ctx.styler
        if ctx.mode == .pretty {
            ctx.write("  " + s.paint("Following NWS alerts for \(place.name). Ctrl-C stops.", Theme.faint))
        }
        while true {
            ctx.refreshClock()
            let fetched = await ctx.alerts(place)
            if let alerts = fetched.value {
                var current: [String: WeatherAlert] = [:]
                for alert in alerts { current[alert.id] = alert }
                for alert in alerts where known[alert.id] == nil {
                    emit(kind: first ? "active" : "new", alert: alert, ctx: ctx, fmt: fmt)
                }
                for (id, alert) in known where current[id] == nil {
                    emit(kind: "ended", alert: alert, ctx: ctx, fmt: fmt)
                }
                if first && alerts.isEmpty && ctx.mode == .pretty {
                    ctx.write("  " + s.paint("No active alerts right now.", Theme.mint))
                }
                known = current
                first = false
            } else if ctx.mode == .json {
                struct Problem: Encodable { let type = "unavailable"; let error: String; let at: Date }
                ctx.writeJSON(Problem(error: fetched.error ?? "unknown error", at: ctx.now))
            } else {
                ctx.write("  " + s.paint("\(fmt.time(ctx.now))  Alerts unavailable: \(fetched.error ?? "unknown error"). Retrying.", Theme.advisory))
            }
            try? await Task.sleep(nanoseconds: 120 * 1_000_000_000)
        }
    }

    static func emit(kind: String, alert: WeatherAlert, ctx: Context, fmt: Formatter) {
        switch ctx.mode {
        case .json:
            struct Event: Encodable { let type: String; let at: Date; let alert: AlertJSON }
            let encoder = JSONEncoder.dreadcast
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(Event(type: kind, at: ctx.now, alert: AlertJSON(alert))), let text = String(data: data, encoding: .utf8) {
                Console.write(text + "\n")
            }
        case .plain:
            ctx.write("\(fmt.time(ctx.now)) \(kind): \(alert.event)" + (alert.endsOrExpires.map { " until \(fmt.until($0, now: ctx.now))" } ?? ""))
        case .pretty:
            let s = ctx.styler
            let color = kind == "ended" ? Theme.faint : NowCommand.alertColor(alert)
            ctx.write("  " + s.paint(fmt.time(ctx.now), Theme.faint) + "  " + s.paint(kind.uppercased(), color, bold: true) + "  " + alert.event
                      + (alert.endsOrExpires.map { s.paint("  until \(fmt.until($0, now: ctx.now))", Theme.mist) } ?? ""))
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
