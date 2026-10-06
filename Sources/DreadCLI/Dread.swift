import Foundation
import DreadcastKit
import DreadTerminal

/// Entry point shared by the `dread` executable and the tests.
public enum Dread {
    public static func run(_ rawArguments: [String]) async -> ExitCode {
        let arguments: Arguments
        do {
            arguments = try Arguments.parse(rawArguments)
        } catch {
            Console.writeError("dread: \(error.userMessage)\n")
            return .usage
        }
        let context = Context(arguments: arguments)
        if arguments.has("help") || arguments.command == "help" {
            let topic = arguments.command == "help" ? arguments.positionals.first : arguments.command
            context.write(Help.text(for: topic, styler: context.styler))
            return .ok
        }
        do {
            switch arguments.command {
            case "version":
                context.write("dread \(DreadcastKit.Dreadcast.version)")
                return .ok
            case "now", "weather":
                return context.opensApp ? try await DreadApp.run(context, tab: .now) : try await NowCommand.run(context)
            case "radar": return try await RadarCommand.run(context)
            case "alerts": return try await AlertsCommand.run(context)
            case "prompt": return await PromptCommand.run(context)
            case "refresh": return await RefreshCommand.run(context)
            case "forecast": return try await ForecastCommand.run(context)
            case "outlook": return try await OutlookCommand.run(context)
            case "top": return try await TopCommand.run(context)
            case "lightning": return try await LightningCommand.run(context)
            case "eta": return try await EtaCommand.run(context)
            case "scene": return try await SceneCommand.run(context)
            case "setup": return try await SetupCommand.run(context)
            case "places": return try await PlacesCommand.run(context)
            case "auth": return try AuthCommand.run(context)
            case "config": return try ConfigCommand.run(context)
            case "credits": return CreditsCommand.run(context)
            default:
                return context.fail("Unknown command \(arguments.command).", code: .usage)
            }
        } catch let error as Context.LocationError {
            return context.fail(error.userMessage, code: .setupRequired)
        } catch {
            return context.fail(error.userMessage, code: .unavailable)
        }
    }
}

enum Help {
    static func text(for topic: String?, styler: Styler) -> String {
        let title = styler.paint("dread", Theme.lamp, bold: true)
        switch topic {
        case "radar":
            return """
            \(title) radar — animated radar for your location

              --range <15|35|75|150|300>   view radius in miles (default from config, 35)
              --palette <name>             dreadcast, classic, viridis or rainviewer
              --renderer <name>            auto, kitty, iterm2, halfblock or 256
              --frames <n>                 frames in the loop, 2–12 (default 8)
              --still                      show the latest frame without animating
              --once                       play the loop once, then exit
              --no-lightning               hide lightning even when configured
              --location <query>           ZIP code, place name or lat,lon

            Keys while animating: space pauses, ←/→ step frames, +/− change range, q quits.
            """
        case "alerts":
            return """
            \(title) alerts — active NWS watches, warnings and advisories

              --follow                     keep running and print changes every 2 minutes
              --fail-on <level>            exit 1 if an alert is active at or above
                                           minor, moderate, severe or extreme
              --all                        every saved place (see dread help places)
              --json                       structured output

            Exit codes: 0 nothing at or above the level, 1 an alert is active,
            3 alert data unavailable or stale. Missing data is never reported as clear.
            With --all, 1 means any place, and 3 means any US place couldn't be checked.
            """
        case "prompt":
            return """
            \(title) prompt — a fast segment for shell prompts and status lines

              --format <style>             plain (default), tmux, starship or json

            Reads only the cache and returns immediately. When the cache is older than
            ten minutes it starts one background refresh.
            """
        case "eta":
            return """
            \(title) eta — when rain reaches you, from recent radar motion

            Traces echo motion across the last four radar frames. Timing guidance only:
            it can't foresee storms that form or fade along the way.
            """
        case "setup":
            return """
            \(title) setup — choose a location and units

              dread setup                  interactive
              dread setup 33602            ZIP code
              dread setup "Lisbon"         place search
              dread setup 27.95,-82.46     coordinates
              --units imperial|metric

            Coordinates are rounded to two decimal places (about 1 km) before they are
            saved or sent anywhere.
            """
        case "auth":
            return """
            \(title) auth — optional lightning credentials

              dread auth xweather          save an Xweather client ID and secret (Keychain on macOS,
                                           a private file on Linux)
              dread auth status            show what is configured
              dread auth remove xweather   delete saved credentials

            Or set DREADCAST_XWEATHER_CLIENT_ID and DREADCAST_XWEATHER_CLIENT_SECRET.
            """
        case "config":
            return """
            \(title) config — show or change preferences

              dread config                 show settings and file locations
              dread config set <key> <value>
                units imperial|metric · palette dreadcast|classic|viridis|rainviewer
                range 15|35|75|150|300 · renderer auto|kitty|iterm2|halfblock|256
                quips on|off · icons emoji|ascii
                scene <name>|daily · scene-banner on|off
            """
        case "top", "app":
            return """
            \(title) — the app

              dread                        opens on Now
              dread top [view]             opens on a view: now, systems, radar, forecast,
                                           alerts, outlook, lightning, scene or places (or 1–9)
              dread -l <name>              opens on a saved place

            Keys: tab and shift-tab or 1–9 switch views · [ and ] switch places · a goes to
            the most serious alert · ↑/↓ select or scroll · r refresh · q quits. Radar: space
            pauses, ←/→ step frames, +/− change range. Scene: ←/→ change scene, t the time
            of day. Places: enter shows the highlighted place in full.

            Every view reads the same live data, and each source refreshes on its own
            schedule. A new alert shows in the header whichever view is open.

            With saved places (dread places), the app watches all of them: alerts every
            2 minutes and conditions every 10. The place you're viewing gets everything.

            Piped, or with --plain or --json, `dread` prints the quick look instead, as
            `dread now` always does.
            """
        case "places":
            return """
            \(title) places — save places under short names

              dread places                 list them; the first is your default
              dread places add <place>     ZIP code, place name or lat,lon
                    --name <name>          a short name (default: the town)
              dread places remove <name>
              dread places default <name>
              dread places rename <name> <new-name>

            Any command takes a saved name: dread now -l mom. Up to \(PlaceBook.limit) places.

              dread now --all              one row per place
              dread alerts --all           alerts at every place; with --fail-on, exits 1
                                           when any place has one at or above the level
              dread alerts --follow --all  changes at every place, each line named

            In the app, the Places tab lists them all and [ ] switch between them. Each
            saved place is sent to Open-Meteo and the NWS on every refresh, rounded to
            about 1 km.
            """
        case "scene":
            return """
            \(title) scene — the Dreadcast scenes as pixel art, with live conditions

              dread scene                  your scene, animated, filling the terminal
              dread scene <name>           \(SceneID.allCases.map(\.rawValue).joined(separator: ", "))
              --time <auto|dawn|day|dusk|night>
                                           auto follows the local hour, as in the app
              --still                      one composed frame, inline
              --png <file>                 save the artwork as a PNG (--size 120x40,
                                           --layout window|panorama|strip, --at <seconds>)

            Keys: ←/→ change scene, t cycles the time of day, i hides the readings,
            space pauses, q quits. Scenes are decorative and never describe the weather;
            the readings below them are real. Reduce Motion shows a still frame.

            `dread config set scene <name|daily>` picks your scene (Asteroid Watch by default);
            `dread config set scene-banner off` hides it on the Now tab and in `dread now`.
            """
        default:
            return """
            \(title) — weather and radar for the command line. \(styler.paint("There’s a lot in the forecast.", Theme.lamp, italic: true))

            \(styler.bold("Every day"))
              dread                        the app: now, systems, radar, forecast, alerts,
                                           outlook, lightning and your scene, one tab each
              dread now                    a quick look: your scene, conditions, alerts, the
                                           next two hours and five days (also: dread weather)
              dread radar                  animated radar with lightning
              dread alerts                 active watches, warnings and advisories
              dread prompt                 a cached segment for prompts and status lines

            \(styler.bold("Weather enthusiasts"))
              dread forecast               hourly and 7-day forecast
              dread eta                    rain arrival from radar motion
              dread outlook                solar, aurora, earthquakes, meteors and hazards
              dread lightning              strike map (needs Xweather credentials)
              dread scene                  the Dreadcast scenes as animated pixel art

            \(styler.bold("Setup"))
              dread setup                  choose a location
              dread places                 save more places and watch them all
              dread auth xweather          optional lightning credentials
              dread config                 preferences
              dread credits                data sources and licenses

            \(styler.bold("Common options"))
              --location <query>           ZIP code, place name or lat,lon
              --units imperial|metric      --json   --plain   --no-color   --ascii

            Run `dread help <command>` for details. Readings come straight from public
            providers; dreadcast has no account and no server.
            """
        }
    }
}
