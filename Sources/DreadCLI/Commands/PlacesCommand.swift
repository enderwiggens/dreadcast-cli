import Foundation
import DreadcastKit
import DreadTerminal

/// `dread places`: save places under short names. The first is the default; the others
/// can be named with `--location`, watched with `--all` and switched to in the app.
enum PlacesCommand {
    static func run(_ ctx: Context) async throws -> ExitCode {
        let words = ctx.arguments.positionals
        let action = words.first?.lowercased() ?? "list"
        var places = ctx.config.places
        let message: String
        do {
            switch action {
            case "list", "ls":
                return list(ctx)
            case "add":
                let query = words.dropFirst().joined(separator: " ")
                guard !query.isEmpty else { return ctx.fail("Pass a ZIP code, place name or lat,lon: dread places add 33602 --name mom", code: .usage) }
                let interactive = ctx.terminal.isInputTTY && ctx.mode != .json
                let place = SetupCommand.choose(try await PlaceService(http: ctx.http).resolve(query), ctx: ctx, interactive: interactive)
                places = try PlaceBook.add(place, name: ctx.arguments.value("name"), to: places)
                let saved = places[places.count - 1]
                message = places.count == 1
                    ? "Saved \(saved.name): \(place.name), your default place."
                    : "Saved \(saved.name): \(place.name). Try `dread now -l \(saved.name)`, `dread now --all` or the Places tab in `dread`."
            case "remove", "rm":
                guard words.count == 2 else { return ctx.fail("Usage: dread places remove <name>", code: .usage) }
                places = try PlaceBook.remove(words[1], from: places)
                message = "Removed \(words[1].lowercased())." + (places.first.map { " Your default is \($0.name)." } ?? "")
            case "default":
                guard words.count == 2 else { return ctx.fail("Usage: dread places default <name>", code: .usage) }
                places = try PlaceBook.makeDefault(words[1], in: places)
                message = "\(places[0].name) (\(places[0].place.name)) is now your default place."
            case "rename":
                guard words.count == 3 else { return ctx.fail("Usage: dread places rename <name> <new-name>", code: .usage) }
                places = try PlaceBook.rename(words[1], to: words[2], in: places)
                message = "Renamed \(words[1].lowercased()) to \(words[2].lowercased())."
            default:
                return ctx.fail("Unknown action \(action). Use list, add, remove, default or rename.", code: .usage)
            }
        } catch let problem as PlaceBook.Problem {
            return ctx.fail(problem.errorDescription ?? "Couldn’t change your places.", code: .usage)
        }
        var config = ctx.config
        config.places = places
        try ConfigStore.save(config, to: ctx.paths)
        if ctx.mode == .json {
            ctx.writeJSON(PlacesJSON(places))
        } else {
            ctx.write(ctx.mode == .pretty ? "  " + ctx.styler.paint(message, Theme.mint) : message)
        }
        return .ok
    }

    static func list(_ ctx: Context) -> ExitCode {
        let places = ctx.config.places
        switch ctx.mode {
        case .json:
            ctx.writeJSON(PlacesJSON(places))
        case .plain:
            if places.isEmpty { ctx.write("No saved places. Run `dread setup` or `dread places add <place>`.") }
            for (i, saved) in places.enumerated() {
                ctx.write("\(saved.name): \(saved.place.name) (\(saved.place.coordinate.formatted))" + (i == 0 ? ", default" : ""))
            }
        case .pretty:
            let s = ctx.styler
            var lines = ["", "  " + s.paint("PLACES", Theme.porcelain, bold: true) + s.paint("  ·  the first is your default", Theme.faint), ""]
            if places.isEmpty {
                lines.append("  " + s.paint("No saved places yet.", Theme.mist))
            }
            for (i, saved) in places.enumerated() {
                lines.append("  " + s.paint(i == 0 ? "●" : " ", Theme.lamp) + " " + s.paint(saved.name.padding(14), Theme.porcelain, bold: true)
                             + saved.place.name.padding(28) + s.paint(saved.place.coordinate.formatted, Theme.faint))
            }
            lines.append("")
            lines.append("  " + s.paint("dread places add <place> --name <name>", Theme.lamp) + s.paint("  ·  remove · default · rename", Theme.mist))
            lines.append("  " + s.paint("Each saved place is sent to Open-Meteo and the NWS on every refresh, rounded to about 1 km.", Theme.faint))
            lines.append("")
            ctx.write(lines)
        }
        return .ok
    }
}

struct PlacesJSON: Encodable {
    struct Entry: Encodable {
        let name: String
        let isDefault: Bool
        let location: LocationJSON
    }
    let schema = "dreadcast.places/1"
    let places: [Entry]

    init(_ places: [SavedPlace]) {
        self.places = places.enumerated().map { Entry(name: $1.name, isDefault: $0 == 0, location: LocationJSON($1.place)) }
    }
}
