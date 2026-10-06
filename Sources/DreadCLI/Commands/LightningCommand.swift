import Foundation
import DreadcastKit
import DreadTerminal

/// `dread lightning`: recent strikes as Braille dots in the five age colors.
enum LightningCommand {
    static func run(_ ctx: Context) async throws -> ExitCode {
        let place = try await ctx.resolveLocation()
        let radius = min(XweatherLightningService.maximumRadiusMiles, max(5, ctx.arguments.double("radius") ?? XweatherLightningService.maximumRadiusMiles))
        guard Credentials.xweather(environment: ctx.environment) != nil else {
            return ctx.fail("Lightning uses your own Xweather account. Run `dread auth xweather` to add credentials.", code: .setupRequired)
        }
        let watch = ctx.arguments.has("watch") && ctx.mode == .pretty
        var previousLines = 0
        if watch { InterruptGuard.install(cleanup: TerminalControl.showCursor + "\n"); Console.write(TerminalControl.hideCursor) }
        defer { if watch { InterruptGuard.clear(); Console.write(TerminalControl.showCursor) } }

        while true {
            guard let fetched = await ctx.lightning(place, radiusMiles: radius) else { return .setupRequired }
            guard let snapshot = fetched.value else {
                return ctx.fail("Lightning is unavailable: \(fetched.error ?? "unknown error").", code: .unavailable)
            }
            let fmt = Formatter(units: ctx.units, timeZone: ctx.timeZone(for: place))
            switch ctx.mode {
            case .json:
                ctx.writeJSON(LightningDetailJSON(place: place, snapshot: snapshot, now: ctx.now, stale: fetched.isStale))
                return .ok
            case .plain:
                let strikes = snapshot.current(at: ctx.now)
                var lines = ["\(strikes.count) lightning strikes within \(fmt.distance(miles: snapshot.radiusMiles)) of \(place.name) in the last 20 minutes (Xweather)."]
                if let nearest = snapshot.nearest(at: ctx.now) {
                    lines.append("Nearest: \(fmt.distance(miles: nearest.miles)) \(Compass.word(snapshot.center.bearingDegrees(to: nearest.strike.coordinate))), \(Formatter.ago(nearest.strike.timestamp, now: ctx.now)).")
                }
                ctx.write(lines)
                return .ok
            case .pretty:
                let lines = pretty(place: place, snapshot: snapshot, fetched: fetched, fmt: fmt, ctx: ctx, watching: watch)
                Console.write((previousLines > 0 ? TerminalControl.moveUp(previousLines) : "") + lines.map { "\r" + TerminalControl.clearLine + $0 }.joined(separator: "\n") + "\n")
                previousLines = lines.count
            }
            guard watch else { return .ok }
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            ctx.refreshClock()
        }
    }

    static func pretty(place: Place, snapshot: LightningSnapshot, fetched: Fetched<LightningSnapshot>,
                       fmt: Formatter, ctx: Context, watching: Bool, width: Int? = nil, height: Int? = nil) -> [String] {
        let s = ctx.styler
        let columns = min(max((width ?? ctx.terminal.columns) - 4, 40), 96)
        let rows = max(height == nil ? 10 : 6, min((height ?? ctx.terminal.rows) - 10, columns / 3))
        // One basemap pixel per cell for the background, Braille dots for strikes.
        let cellViewport = RadarViewport(center: place.coordinate, rangeMiles: snapshot.radiusMiles, width: columns, height: rows * 2)
        let scene = RadarScene(viewport: cellViewport, palette: ctx.config.palette, minimumDBZ: 99, units: ctx.units)
        let full = scene.base()
        var background = Raster(width: columns, height: rows)
        for y in 0..<rows { for x in 0..<columns { background[x, y] = Raster.mix(full[x, y * 2], full[x, y * 2 + 1], 0.5) } }

        var canvas = BrailleCanvas(columns: columns, rows: rows)
        let dotsPerMile = Double(canvas.dotWidth) / (2 * snapshot.radiusMiles)
        let strikes = snapshot.current(at: ctx.now).sorted { $0.timestamp < $1.timestamp }
        for strike in strikes {
            let offset = snapshot.center.milesTo(strike.coordinate)
            let x = Int((Double(canvas.dotWidth) / 2 + offset.east * dotsPerMile).rounded(.down))
            // Braille dots are square when cells are twice as tall as they are wide.
            let y = Int((Double(canvas.dotHeight) / 2 - offset.north * dotsPerMile).rounded(.down))
            canvas.set(dotX: x, dotY: y, color: Theme.lightning[strike.ageBand(at: ctx.now).rawValue].hex)
        }
        let markers = [CellOverlay(column: columns / 2, row: rows / 2, character: "✛", color: Theme.lamp, bold: true)]
            + CellOverlay.text(" " + (place.name.components(separatedBy: ",").first ?? place.name), column: columns / 2 + 1, row: rows / 2, color: Theme.porcelain, bold: true)

        var lines = [""]
        let status = (fetched.isStale ? "stale · " : "") + "updated " + Formatter.ago(fetched.storedAt ?? ctx.now, now: ctx.now) + (watching ? " · refreshes every minute" : "")
        lines.append(TextWidth.spread(ctx.title("LIGHTNING", place: place)
                                      + s.paint("  ·  \(fmt.distance(miles: snapshot.radiusMiles)) radius", Theme.mist),
                                      s.paint("XWEATHER · " + status, fetched.isStale ? Theme.advisory : Theme.faint), width: columns + 2))
        lines.append(contentsOf: canvas.render(styler: s, background: background, overlays: markers).map { "  " + $0 })

        var counts = [Int](repeating: 0, count: 5)
        for strike in strikes { counts[strike.ageBand(at: ctx.now).rawValue] += 1 }
        let legend = LightningAgeBand.allCases.map { band in
            s.paint("● \(band.label)", Theme.lightning[band.rawValue]) + s.paint(" \(counts[band.rawValue])", Theme.porcelain)
        }.joined(separator: "   ")
        lines.append("  " + legend)
        if let nearest = snapshot.nearest(at: ctx.now) {
            let bearing = Compass.point(snapshot.center.bearingDegrees(to: nearest.strike.coordinate))
            let kinds = strikes.reduce(into: (cg: 0, ic: 0)) { result, strike in
                if strike.kind == .cloudToGround { result.cg += 1 } else if strike.kind == .intracloud { result.ic += 1 }
            }
            lines.append("  \(strikes.count) strikes in 20 min · nearest " + s.paint("\(fmt.distance(miles: nearest.miles, decimals: true)) \(bearing)", Theme.lightning[0])
                         + s.paint(", \(Formatter.ago(nearest.strike.timestamp, now: ctx.now))", Theme.faint)
                         + s.paint(" · \(kinds.cg) cloud-to-ground, \(kinds.ic) in-cloud", Theme.mist))
        } else {
            lines.append("  " + s.paint("No strikes within \(fmt.distance(miles: snapshot.radiusMiles)) in the last 20 minutes.", Theme.mint))
        }
        lines.append("")
        return lines
    }
}

struct LightningDetailJSON: Encodable {
    struct Strike: Encodable { let latitude: Double; let longitude: Double; let time: Date; let kind: String; let ageBand: Int; let distanceMiles: Double }
    let schema = "dreadcast.lightning/1"
    let location: LocationJSON
    let source = "xweather"
    let radiusMiles: Double
    let fetchedAt: Date
    let stale: Bool
    let strikes: [Strike]

    init(place: Place, snapshot: LightningSnapshot, now: Date, stale: Bool) {
        location = LocationJSON(place)
        radiusMiles = snapshot.radiusMiles
        fetchedAt = snapshot.fetchedAt
        self.stale = stale
        strikes = snapshot.current(at: now).map {
            Strike(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, time: $0.timestamp, kind: $0.kind.rawValue,
                   ageBand: $0.ageBand(at: now).rawValue, distanceMiles: ($0.coordinate.distanceMiles(to: snapshot.center) * 10).rounded() / 10)
        }
    }
}
