import Foundation
import DreadcastKit
import DreadTerminal
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `dread prompt`: reads only the cache, so it is fast enough for every shell prompt.
/// When the cache is stale it starts a single background refresh.
enum PromptCommand {
    static func run(_ ctx: Context) async -> ExitCode {
        guard let place = ctx.config.location else { return .setupRequired }
        let key = Context.placeKey(place)
        let units = ctx.units
        let weather = ctx.cached(WeatherReport.self, key: "weather-\(key)-\(units.rawValue)")
        let alerts = ctx.cached([WeatherAlert].self, key: "alerts-\(key)")
        let lightning = ctx.cached(LightningSnapshot.self, key: "lightning-\(key)-\(Int(XweatherLightningService.maximumRadiusMiles))")

        if weather.map({ ctx.now.timeIntervalSince($0.storedAt) > 600 }) ?? true {
            startBackgroundRefresh(ctx)
        }
        guard let report = weather?.value, ctx.now.timeIntervalSince(weather!.storedAt) < 3 * 3600 else {
            return .unavailable
        }

        let fmt = Formatter(units: units, timeZone: report.timeZone)
        let icon = ctx.config.icons == "ascii" ? WeatherCondition.ascii(report.current.weatherCode, isDay: report.current.isDay)
            : WeatherCondition.emoji(report.current.weatherCode, isDay: report.current.isDay)
        let temperature = fmt.temperature(report.current.temperature)
        let activeAlerts = (alerts.map { ctx.now.timeIntervalSince($0.storedAt) < 3600 ? $0.value : [] } ?? [])
            .filter { ($0.endsOrExpires ?? .distantFuture) > ctx.now }
        let worst = activeAlerts.sorted(by: WeatherAlert.threatOrder).first
        let strikes = lightning.map { ctx.now.timeIntervalSince($0.storedAt) < 900 ? $0.value.current(at: ctx.now).count : 0 } ?? 0

        switch (ctx.arguments.value("format") ?? "plain").lowercased() {
        case "json":
            struct PromptJSON: Encodable {
                let temperature: Double?
                let units: String
                let condition: String
                let icon: String
                let alert: String?
                let alertLevel: String?
                let alertEnds: Date?
                let strikes20m: Int
                let updated: Date
            }
            ctx.writeJSON(PromptJSON(temperature: report.current.temperature, units: units.rawValue,
                                     condition: WeatherCondition.description(report.current.weatherCode), icon: icon,
                                     alert: worst?.event, alertLevel: worst?.level.rawValue, alertEnds: worst?.endsOrExpires,
                                     strikes20m: strikes, updated: weather!.storedAt))
        case "tmux":
            var text = "\(icon) \(temperature)\(units == .imperial ? "F" : "C")"
            if let worst {
                let color = worst.level >= .warning ? "#ff947d" : "#f4d487"
                text += " #[fg=\(color)]▲ \(shortName(worst.event))"
                if let end = worst.endsOrExpires { text += " til \(fmt.time(end).replacingOccurrences(of: " PM", with: "").replacingOccurrences(of: " AM", with: ""))" }
                text += "#[default]"
            }
            if strikes > 0 { text += " ⚡\(strikes)" }
            ctx.write(text)
        default:
            var text = "\(icon) \(temperature)"
            if strikes > 0 { text += " ⚡\(strikes)" }
            if let worst { text += " ▲ " + shortName(worst.event).lowercased() }
            ctx.write(text)
        }
        return .ok
    }

    /// "Severe Thunderstorm Warning" → "Svr T-Storm Warning".
    static func shortName(_ event: String) -> String {
        event.replacingOccurrences(of: "Severe Thunderstorm", with: "Svr T-Storm")
            .replacingOccurrences(of: "Thunderstorm", with: "T-Storm")
            .replacingOccurrences(of: "Special Marine", with: "Spcl Marine")
            .replacingOccurrences(of: "Small Craft", with: "Sm Craft")
    }

    static func startBackgroundRefresh(_ ctx: Context) {
        // At most one refresh request per minute across every shell.
        if let last = ctx.cache.read(Date.self, key: "refresh-requested"), ctx.now.timeIntervalSince(last.value) < 60 { return }
        ctx.cache.write(ctx.now, key: "refresh-requested", at: ctx.now)
        guard let executable = Bundle.main.executableURL ?? URL(string: "file://" + CommandLine.arguments[0]) else { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["refresh", "--quiet"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// `dread refresh`: updates the cache for the saved location. Used by the prompt.
enum RefreshCommand {
    static func run(_ ctx: Context) async -> ExitCode {
        guard let place = ctx.config.location else { return .setupRequired }
        let result: ExitCode? = await withLock(ctx) {
            async let weather = ctx.weather(place)
            async let alerts = ctx.alerts(place)
            async let lightning = ctx.lightning(place)
            let (w, a, _) = await (weather, alerts, lightning)
            if !ctx.arguments.has("quiet") {
                ctx.write(w.value == nil ? "Conditions unavailable: \(w.error ?? "unknown error")" : "Updated conditions for \(place.name).")
                if place.isUnitedStates { ctx.write(a.value == nil ? "Alerts unavailable: \(a.error ?? "unknown error")" : "Updated alerts.") }
            }
            return w.value == nil ? .unavailable : .ok
        }
        return result ?? .ok
    }

    /// Skips the refresh when another dreadcast process is already running one.
    static func withLock(_ ctx: Context, _ body: () async -> ExitCode) async -> ExitCode? {
        let path = ctx.paths.cacheDirectory.appendingPathComponent("refresh.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return await body() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return await body()
    }
}
