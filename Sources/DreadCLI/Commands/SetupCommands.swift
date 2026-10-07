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

/// Reads one line from standard input, optionally without echo (for secrets).
enum Prompt {
    static func ask(_ question: String, secret: Bool = false) -> String? {
        Console.write(question)
        var original = termios()
        let canHide = secret && isatty(STDIN_FILENO) != 0 && tcgetattr(STDIN_FILENO, &original) == 0
        if canHide {
            var hidden = original
            hidden.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &hidden)
        }
        defer {
            if canHide {
                tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
                Console.write("\n")
            }
        }
        return readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `dread setup`: choose a location and units.
enum SetupCommand {
    /// The first match, or the one the person picks when several match.
    static func choose(_ places: [Place], ctx: Context, interactive: Bool) -> Place {
        guard places.count > 1, interactive else { return places[0] }
        let s = ctx.styler
        ctx.write("")
        for (index, candidate) in places.enumerated() {
            ctx.write("  " + s.paint("\(index + 1)", ctx.highlight) + "  " + candidate.name + s.paint("  \(candidate.coordinate.formatted)", Theme.faint))
        }
        if let answer = Prompt.ask("\n  Which one? [1]: "), let choice = Int(answer), (1...places.count).contains(choice) {
            return places[choice - 1]
        }
        return places[0]
    }

    static func run(_ ctx: Context) async throws -> ExitCode {
        let s = ctx.styler
        let interactive = ctx.terminal.isInputTTY && ctx.mode != .json
        var query = ctx.arguments.positionals.joined(separator: " ")
        if query.isEmpty, let flag = ctx.arguments.value("location") { query = flag }
        if query.isEmpty {
            guard interactive else { return ctx.fail("Pass a ZIP code, place name or lat,lon: dread setup 33602", code: .usage) }
            ctx.write(["", "  " + s.paint("DREADCAST", Theme.porcelain, bold: true) + s.paint("  ·  setup", Theme.faint), ""])
            guard let answer = Prompt.ask("  Where should Dreadcast forecast? ZIP code, place name, or lat,lon: "), !answer.isEmpty else {
                return ctx.fail("No location entered.", code: .usage)
            }
            query = answer
        }

        let place = choose(try await PlaceService(http: ctx.http).resolve(query), ctx: ctx, interactive: interactive)

        var config = ctx.config
        config.location = place
        if let units = ctx.arguments.value("units") {
            config.units = ["metric", "c", "celsius"].contains(units.lowercased()) ? .metric : .imperial
        } else if interactive, ctx.config.location == nil {
            let suggested: UnitSystem = place.isUnitedStates ? .imperial : .metric
            let answer = Prompt.ask("  Units: imperial or metric? [\(suggested.rawValue)]: ")?.lowercased() ?? ""
            config.units = answer.hasPrefix("m") ? .metric : answer.hasPrefix("i") ? .imperial : suggested
        }
        try ConfigStore.save(config, to: ctx.paths)

        if ctx.mode == .json {
            struct Saved: Encodable { let location: LocationJSON; let units: String; let configFile: String }
            ctx.writeJSON(Saved(location: LocationJSON(place), units: config.units.rawValue, configFile: ctx.paths.configFile.path))
        } else {
            ctx.write([
                "",
                "  " + s.paint("Saved", Theme.mint, bold: true) + "  \(place.name) " + s.paint("(\(place.coordinate.formatted))", Theme.faint) + " · \(config.units.rawValue)",
                "  " + s.paint("Coordinates are rounded to two decimals (about 1 km) before they are stored or sent.", Theme.faint),
                "  " + s.paint("Next: ", Theme.mist) + "dread" + s.paint(" · ", Theme.faint) + "dread radar" + s.paint(" · ", Theme.faint) + "dread help",
                ""
            ])
        }
        return .ok
    }
}

/// `dread auth`: optional Xweather credentials for lightning.
enum AuthCommand {
    static func run(_ ctx: Context) throws -> ExitCode {
        let s = ctx.styler
        let action = ctx.arguments.positionals.first?.lowercased() ?? "status"
        switch action {
        case "status":
            let source = Credentials.source(environment: ctx.environment)
            ctx.write("  Xweather lightning: " + (source.map { s.paint("configured (\($0))", Theme.mint) } ?? s.paint("not configured", Theme.faint)))
            return .ok
        case "remove":
            Credentials.removeXweather()
            ctx.write("  Removed saved Xweather credentials.")
            return .ok
        case "xweather":
            var id = ctx.arguments.value("client-id")
            var secret = ctx.arguments.value("client-secret")
            if id == nil || secret == nil {
                guard ctx.terminal.isInputTTY else {
                    return ctx.fail("Run this in a terminal, or set DREADCAST_XWEATHER_CLIENT_ID and DREADCAST_XWEATHER_CLIENT_SECRET.", code: .usage)
                }
                #if canImport(Security)
                let storage = "  Credentials are stored in the login Keychain and never written to files or output."
                #else
                let storage = "  Credentials are stored in \(Credentials.credentialsFile.path), readable only by you."
                #endif
                ctx.write(["", "  Lightning uses your own Xweather account (https://www.xweather.com/).", storage, ""])
                id = Prompt.ask("  Client ID: ")
                secret = Prompt.ask("  Client secret (hidden): ", secret: true)
            }
            guard let id, let secret, !id.isEmpty, !secret.isEmpty else {
                return ctx.fail("Both a client ID and a client secret are needed.", code: .usage)
            }
            try Credentials.saveXweather(LightningCredentials(clientID: id, clientSecret: secret))
            ctx.write("  " + s.paint("Saved.", Theme.mint) + " Lightning appears in `dread`, `dread radar` and `dread lightning`.")
            return .ok
        default:
            return ctx.fail("Use `dread auth xweather`, `dread auth status` or `dread auth remove`.", code: .usage)
        }
    }
}

/// `dread config`: show or change preferences.
enum ConfigCommand {
    static func run(_ ctx: Context) throws -> ExitCode {
        let s = ctx.styler
        let parts = ctx.arguments.positionals
        if parts.first == "set" {
            guard parts.count >= 3 else { return ctx.fail("Use: dread config set <key> <value>", code: .usage) }
            var config = ctx.config
            let value = parts[2].lowercased()
            switch parts[1].lowercased() {
            case "units":
                guard let units = UnitSystem(rawValue: value) else { return ctx.fail("units: imperial or metric.", code: .usage) }
                config.units = units
            case "palette":
                guard let palette = RadarPalette(rawValue: value) else { return ctx.fail("palette: dreadcast, classic, viridis or rainviewer.", code: .usage) }
                config.palette = palette
            case "range":
                guard let range = Int(value), Config.ranges.contains(range) else { return ctx.fail("range: 15, 35, 75, 150 or 300.", code: .usage) }
                config.radarRange = range
            case "renderer":
                guard ["auto", "kitty", "iterm2", "halfblock", "256"].contains(value) else { return ctx.fail("renderer: auto, kitty, iterm2, halfblock or 256.", code: .usage) }
                config.renderer = value
            case "quips":
                config.quips = ["on", "true", "yes", "1"].contains(value)
            case "icons":
                guard ["emoji", "ascii"].contains(value) else { return ctx.fail("icons: emoji or ascii.", code: .usage) }
                config.icons = value
            case "highlight":
                guard let highlight = Highlight.named(value) else { return ctx.fail("highlight: \(Highlight.names).", code: .usage) }
                config.highlight = highlight.rawValue
            case "map":
                guard let map = MapChoice.named(value) else { return ctx.fail("map: theme (follows your scene) or graphite.", code: .usage) }
                config.map = map.rawValue
            case "forecast":
                guard let row = ForecastRow.named(value) else { return ctx.fail("forecast: days, hourly or off.", code: .usage) }
                config.forecast = row.rawValue
            case "scene":
                if value == "off" {
                    // Hiding the art is its own setting; accept the obvious phrasing too.
                    config.sceneBanner = false
                    try ConfigStore.save(config, to: ctx.paths)
                    ctx.write("  Saved scene-banner = off.")
                    return .ok
                } else if value == "daily" {
                    config.scene = value
                } else if case .scene(let scene) = SceneID.lookup(value) {
                    config.scene = scene.rawValue
                } else if case .pro(let title) = SceneID.lookup(value) {
                    return ctx.fail("\(title) is a Pro scene in the Dreadcast app. Free scenes: \(SceneID.names).", code: .usage)
                } else {
                    return ctx.fail("scene: daily, or one of \(SceneID.names).", code: .usage)
                }
            case "scene-banner", "banner":
                guard ["on", "off", "true", "false", "yes", "no", "1", "0"].contains(value) else {
                    return ctx.fail("scene-banner: on or off.", code: .usage)
                }
                config.sceneBanner = ["on", "true", "yes", "1"].contains(value)
            default:
                return ctx.fail("Unknown setting \(parts[1]).", code: .usage)
            }
            try ConfigStore.save(config, to: ctx.paths)
            ctx.write("  Saved \(parts[1]) = \(value).")
            return .ok
        }
        if ctx.mode == .json {
            ctx.writeJSON(ctx.config)
            return .ok
        }
        let c = ctx.config
        ctx.write([
            "",
            "  " + s.paint("Location", Theme.mist) + "   " + (c.location.map { "\($0.name) (\($0.coordinate.formatted))" } ?? s.paint("not set · dread setup", Theme.advisory))
                + (c.places.count > 1 ? s.paint("  +\(c.places.count - 1) more: \(c.places.dropFirst().map(\.name).joined(separator: ", ")) · dread places", Theme.faint) : ""),
            "  " + s.paint("Units", Theme.mist) + "      " + c.units.rawValue,
            "  " + s.paint("Palette", Theme.mist) + "    " + c.palette.title,
            "  " + s.paint("Range", Theme.mist) + "      \(c.radarRange) mi",
            "  " + s.paint("Renderer", Theme.mist) + "   " + c.renderer + s.paint("  (detected: \(ctx.terminal.graphics.rawValue), \(ctx.terminal.colorMode))", Theme.faint),
            "  " + s.paint("Quips", Theme.mist) + "      " + (c.quips ? "on" : "off"),
            "  " + s.paint("Icons", Theme.mist) + "      " + c.icons,
            "  " + s.paint("Scene", Theme.mist) + "      " + (c.scene == "daily" ? "daily (a different scene each day)"
                : SceneID(rawValue: c.scene).map { "\($0.title) (\($0.rawValue))" } ?? c.scene),
            "  " + s.paint("Banner", Theme.mist) + "     " + (c.sceneBanner ? "on" : "off") + s.paint("  (the scene on the Now tab and in dread now)", Theme.faint),
            "  " + s.paint("Highlight", Theme.mist) + "  " + s.paint("●", ctx.highlight) + " " + (Highlight.named(c.highlight) ?? .automatic).title
                + (Highlight.named(c.highlight) == .automatic ? s.paint("  (follows the scene)", Theme.faint) : ""),
            "  " + s.paint("Map", Theme.mist) + "        " + ((MapChoice.named(c.map) ?? .theme) == .theme ? "theme" + s.paint("  (follows the scene)", Theme.faint) : "graphite"),
            "  " + s.paint("Forecast", Theme.mist) + "   " + (ForecastRow.named(c.forecast) ?? .days).rawValue + s.paint("  (beside the radar on the Now tab)", Theme.faint),
            "  " + s.paint("Lightning", Theme.mist) + "  " + (Credentials.source(environment: ctx.environment) ?? "not configured"),
            "",
            "  " + s.paint("Config  " + ctx.paths.configFile.path, Theme.faint),
            "  " + s.paint("Cache   " + ctx.paths.cacheDirectory.path, Theme.faint),
            ""
        ])
        return .ok
    }
}

/// `dread credits`: data sources, licenses and attribution.
enum CreditsCommand {
    static func run(_ ctx: Context) -> ExitCode {
        let s = ctx.styler
        let sources: [(String, String, String)] = [
            ("Open-Meteo", "Weather and air quality forecasts, geocoding. CC BY 4.0.", "https://open-meteo.com/"),
            ("RainViewer", "Radar imagery. Free API for personal and non-commercial use.", "https://www.rainviewer.com/api.html"),
            ("National Weather Service", "Active alerts. US government work, public domain.", "https://www.weather.gov/documentation/services-web-api"),
            ("NOAA SPC", "Day 1 convective outlook.", "https://www.spc.noaa.gov/"),
            ("NOAA NHC", "Tropical cyclones.", "https://www.nhc.noaa.gov/"),
            ("NIFC WFIGS", "Wildfire incident locations.", "https://data-nifc.opendata.arcgis.com/"),
            ("NOAA SWPC", "Kp index, aurora (OVATION) and D-RAP radio absorption.", "https://www.swpc.noaa.gov/"),
            ("USGS", "Earthquakes and monitored volcano status.", "https://earthquake.usgs.gov/"),
            ("NTWC / PTWC", "Tsunami bulletins.", "https://www.tsunami.gov/"),
            ("NOAA HMS", "Satellite smoke analysis.", "https://www.ospo.noaa.gov/products/land/hms.html"),
            ("American Meteor Society", "Meteor shower calendar.", "https://www.amsmeteors.org/calendar/"),
            ("Xweather", "Lightning, with your own credentials.", "https://www.xweather.com/"),
            ("Zippopotam.us", "US ZIP code lookup.", "https://zippopotam.us/"),
            ("Natural Earth", "Coastlines, lakes, borders and cities. Public domain.", "https://www.naturalearthdata.com/"),
            ("SunCalc", "Moon phase method. BSD-2-Clause, Vladimir Agafonkin.", "https://github.com/mourner/suncalc")
        ]
        var lines = ["", "  " + s.paint("DATA SOURCES", Theme.porcelain, bold: true), ""]
        for (name, detail, url) in sources {
            lines.append("  " + s.bold(TextWidth.pad(name, to: 24)) + detail)
            lines.append("  " + String(repeating: " ", count: 24) + s.paint(url, Theme.faint))
        }
        lines.append(contentsOf: ["", "  Locations are rounded to two decimals (about 1 km) before they're stored or sent.", ""])
        ctx.write(lines)
        return .ok
    }
}
