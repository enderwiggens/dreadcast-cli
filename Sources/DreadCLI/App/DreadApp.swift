import Foundation
import DreadcastKit
import DreadTerminal

/// The app's views, one tab each.
enum AppTab: Int, CaseIterable, Sendable {
    case radar, systems, forecast, alerts, outlook, lightning, scene, places

    var title: String {
        switch self {
        case .radar: "Radar"
        case .systems: "Systems"
        case .forecast: "Forecast"
        case .alerts: "Alerts"
        case .outlook: "Outlook"
        case .lightning: "Lightning"
        case .scene: "Scene"
        case .places: "Places"
        }
    }

    /// The Places tab appears once there's more than one place to watch.
    static func visible(places: Int) -> [AppTab] {
        places > 1 ? allCases : allCases.filter { $0 != .places }
    }

    static func named(_ name: String) -> AppTab? {
        let key = name.lowercased()
        if let number = Int(key), let tab = AppTab(rawValue: number - 1) { return tab }
        // Radar was called Now before it took the radar in.
        let aliases: [String: AppTab] = ["now": .radar, "home": .radar, "top": .systems]
        return allCases.first { $0.title.lowercased() == key } ?? aliases[key]
    }
}

/// What a view draws in the body: text, or pixel art with text above and below it.
enum AppBody {
    case lines([String])
    case pixels(HalfBlockFrame, above: [String] = [], below: [String])
}

/// A place the app watches, with its latest data.
struct Watched {
    let saved: SavedPlace
    let snapshot: LiveData.Snapshot

    var reading: PlaceRows.Reading {
        PlaceRows.Reading(saved: saved, weather: snapshot.weather, alerts: snapshot.alerts, nowcast: snapshot.nowcast?.value)
    }
}

/// Everything a view needs for one frame. `place` and `snapshot` are the selected place.
struct AppFrame {
    let ctx: Context
    let place: Place
    let snapshot: LiveData.Snapshot
    let width: Int
    let height: Int
    let elapsed: Double
    var places: [Watched] = []
    var selected = 0

    /// Every watched place; just the selected one when the app watches a single place.
    var watched: [Watched] {
        places.isEmpty ? [Watched(saved: SavedPlace(name: "", place: place), snapshot: snapshot)] : places
    }

    var selectedIndex: Int { places.isEmpty ? 0 : selected }

    /// The most serious alert at any watched place, with that place's index and the count.
    var worstAlert: (index: Int, alert: WeatherAlert, count: Int)? {
        let all = watched.enumerated().flatMap { i, w in (w.snapshot.alerts?.value ?? []).map { (i, $0) } }
        guard let worst = all.sorted(by: { WeatherAlert.threatOrder($0.1, $1.1) }).first else { return nil }
        return (worst.0, worst.1, all.count)
    }

    var zone: TimeZone { snapshot.weather?.value?.timeZone ?? ctx.timeZone(for: place) }
    var fmt: Formatter { Formatter(units: ctx.units, timeZone: zone) }
}

protocol AppView: AnyObject {
    /// Seconds between redraws while the view is showing.
    var interval: Double { get }
    /// Key hints for the footer.
    var hints: [(String, String)] { get }
    func body(_ frame: AppFrame) -> AppBody
    /// Returns true when the view used the key.
    func handle(_ key: Key, frame: AppFrame) -> Bool
    /// Called when the app switches to another place.
    func placeChanged()
}

extension AppView {
    func placeChanged() {}
}

/// `dread` in an interactive terminal (and `dread top`): one full-screen app with a tab
/// for each view. Every view reads the same live data, which each source refreshes on
/// its own schedule; nothing is fetched twice when you switch tabs.
enum DreadApp {
    static let headerRows = 3
    static let footerRows = 2
    /// The smallest window the app draws in; below it, it asks for more room.
    static let minimumSize = (columns: 60, rows: 16)

    static func run(_ ctx: Context, tab start: AppTab) async throws -> ExitCode {
        let primary = try await ctx.resolveLocation()
        // Saved places are all watched; a place given with --location that isn't saved
        // is shown on its own.
        var places = ctx.config.places
        var selected = places.firstIndex { $0.place.coordinate == primary.coordinate } ?? -1
        if selected < 0 {
            places = [SavedPlace(name: "here", place: primary)]
            selected = 0
        }
        guard let raw = RawTerminal(alternateScreen: true) else {
            return ctx.fail("Couldn’t take over the terminal.", code: .unavailable)
        }
        defer { raw.restore() }
        ctx.inApp = true
        _ = ctx.tiles   // created up front; views load radar tiles in the background

        let configured = Credentials.xweather(environment: ctx.environment) != nil
        let states = places.map { _ in LiveData.State() }
        for state in states { state.with { $0.lightningConfigured = configured } }
        let placesView = PlacesView()
        let views: [AppTab: AppView] = [
            .radar: RadarView(ctx: ctx), .systems: SystemsView(), .forecast: ForecastView(),
            .alerts: AlertsView(), .outlook: OutlookView(), .lightning: LightningView(), .scene: SceneView(ctx: ctx),
            .places: placesView,
        ]
        let tabs = AppTab.visible(places: places.count)
        var tab = tabs.contains(start) ? start : .radar
        var screen = AppScreen()
        let started = Date()
        var lastDraw = Date.distantPast
        Console.write(TerminalControl.clearScreen)

        func windowSize() -> (Int, Int) { TerminalInfo.windowSize() ?? (ctx.terminal.columns, ctx.terminal.rows) }
        func frame() -> AppFrame {
            let size = windowSize()
            return AppFrame(ctx: ctx, place: places[selected].place, snapshot: states[selected].snapshot,
                            width: max(minimumSize.columns, size.0),
                            height: max(minimumSize.rows, size.1) - headerRows - footerRows, elapsed: Date().timeIntervalSince(started),
                            places: places.count > 1 ? zip(places, states).map { Watched(saved: $0, snapshot: $1.snapshot) } : [],
                            selected: selected)
        }
        func show(_ next: AppTab) {
            guard next != tab, tabs.contains(next) else { return }
            tab = next
            screen.reset()
        }
        func switchPlace(to index: Int) {
            guard index != selected, places.indices.contains(index) else { return }
            selected = index
            for view in views.values { view.placeChanged() }
            screen.reset()
        }

        while true {
            ctx.refreshClock()
            if tab == .outlook { states[selected].with { $0.wantsOutlook = true } }
            for (i, state) in states.enumerated() {
                LiveData.schedule(ctx: ctx, place: places[i].place, state: state,
                                    only: sources(for: i, selected: selected, tab: tab, highlighted: placesView.highlighted))
            }
            let view = views[tab]!
            // Back from Ctrl-Z: the screen was handed back, so draw all of it again.
            if raw.takeResumed() {
                screen.reset()
                lastDraw = .distantPast
            }
            if Date().timeIntervalSince(lastDraw) >= view.interval {
                let size = windowSize()
                if size.0 < minimumSize.columns || size.1 < minimumSize.rows {
                    Console.write(screen.tooSmall(columns: size.0, rows: size.1, styler: ctx.styler))
                } else {
                    Console.write(screen.draw(tab: tab, view: view, frame: frame(), styler: ctx.styler))
                }
                lastDraw = Date()
            }
            guard let key = raw.readKey(timeout: min(0.2, view.interval)) else { continue }
            var redraw = true
            switch key {
            case .character("q"), .character("Q"), .escape, .interrupt:
                return .ok
            case .tab:
                show(tabs[((tabs.firstIndex(of: tab) ?? 0) + 1) % tabs.count])
            case .backTab:
                show(tabs[((tabs.firstIndex(of: tab) ?? 0) + tabs.count - 1) % tabs.count])
            case .character(let c) where c.isNumber:
                if let number = c.wholeNumberValue, let chosen = AppTab(rawValue: number - 1) { show(chosen) }
            case .character("]"):
                switchPlace(to: (selected + 1) % places.count)
            case .character("["):
                switchPlace(to: (selected + places.count - 1) % places.count)
            case .character("a"):
                // Jump to the most serious alert, wherever it is.
                if let worst = frame().worstAlert {
                    switchPlace(to: worst.index)
                    show(.alerts)
                } else {
                    redraw = false
                }
            case .character("r"), .character("R"):
                states[selected].with { $0.lastFetch = [:] }
                ctx.cache.remove(key: "alerts-\(Context.placeKey(places[selected].place))")
            default:
                redraw = view.handle(key, frame: frame())
                if let chosen = placesView.takeChoice() {
                    switchPlace(to: chosen)
                    show(.radar)
                }
            }
            if redraw { lastDraw = .distantPast }
        }
    }

    /// What a place loads: every source for the selected place. The others are watched
    /// lightly, with alerts and conditions, plus rain timing for the row highlighted on
    /// the Places tab.
    static func sources(for index: Int, selected: Int, tab: AppTab, highlighted: Int) -> Set<String>? {
        if index == selected { return nil }
        return tab == .places && highlighted == index ? ["weather", "alerts", "nowcast"] : ["weather", "alerts"]
    }

    // MARK: Frame

    static func header(tab: AppTab, frame f: AppFrame, styler s: Styler) -> [String] {
        let clock = Date()
        let alerts = f.snapshot.alerts?.value ?? []
        var right = s.paint(f.fmt.time(clock) + " " + f.fmt.zoneAbbreviation(clock), Theme.faint) + " "
        // Alerts from every watched place, naming the place when it isn't this one.
        if let worst = f.worstAlert {
            var badge = " ▲ \(worst.count == 1 ? worst.alert.event.uppercased() : "\(worst.count) ALERTS")"
            if worst.index != f.selectedIndex { badge += " · \(f.watched[worst.index].saved.name)" }
            right = s.paint(badge + " ", TextStyle(foreground: Theme.midnight, background: NowCommand.alertColor(worst.alert), bold: true)) + "  " + right
        }
        var left = " " + s.paint("DREADCAST", Theme.porcelain, bold: true) + s.paint("  ·  ", Theme.faint) + f.place.name
        if f.places.count > 1 {
            left += s.paint("  \(f.watched[f.selectedIndex].saved.name) · \(f.selectedIndex + 1) of \(f.places.count)", Theme.faint)
        }
        let elsewhere = f.watched.enumerated().filter { $0.offset != f.selectedIndex }.flatMap { $0.element.snapshot.alerts?.value ?? [] }
        return [TextWidth.spread(left, right, width: f.width),
                tabs(active: tab, alerts: alerts, elsewhere: elsewhere, places: f.places.count, width: f.width, styler: s,
                     highlight: f.ctx.highlight),
                s.paint(String(repeating: "─", count: f.width), Theme.border)]
    }

    /// The tab bar. When every name doesn't fit, other tabs show only their numbers. The
    /// Alerts tab counts this place's alerts; the Places tab counts the other places'.
    static func tabs(active: AppTab, alerts: [WeatherAlert], elsewhere: [WeatherAlert] = [], places: Int = 1,
                     width: Int, styler s: Styler, highlight: RGB = Theme.lamp) -> String {
        func worst(_ list: [WeatherAlert]) -> WeatherAlert? { list.sorted(by: WeatherAlert.threatOrder).first }
        func bar(named: Bool) -> String {
            var line = " "
            for candidate in AppTab.visible(places: places) {
                let counted = candidate == .alerts ? alerts : candidate == .places ? elsewhere : []
                let count = counted.isEmpty ? "" : " \(counted.count)"
                if candidate == active {
                    line += s.paint(" \(candidate.rawValue + 1) \(candidate.title)\(count) ", TextStyle(foreground: Theme.midnight, background: highlight, bold: true))
                } else {
                    let color = worst(counted).map(NowCommand.alertColor) ?? Theme.mist
                    line += " " + s.paint("\(candidate.rawValue + 1)", named ? Theme.faint : Theme.mist)
                        + (named ? " " + s.paint(candidate.title + count, color) : count.isEmpty ? "" : s.paint(count, color)) + " "
                }
            }
            return line
        }
        let full = bar(named: true)
        return TextWidth.of(full) <= width ? full : bar(named: false)
    }

    static func footer(view: AppView, frame f: AppFrame, styler s: Styler) -> [String] {
        var keys = [("tab", "next"), ("1–\(AppTab.visible(places: f.places.count).count)", "views")] + view.hints
        if f.places.count > 1 { keys.append(("[ ]", "place")) }
        if let worst = f.worstAlert, worst.index != f.selectedIndex { keys.append(("a", "go to alert")) }
        keys += [("r", "refresh"), ("q", "quit")]
        let busy = f.snapshot.inFlight.isEmpty ? "" : "updating \(f.snapshot.inFlight.sorted().joined(separator: ", "))…"
        let left = " " + keys.map { s.paint($0.0, f.ctx.highlight) + " " + s.paint($0.1, Theme.mist) }.joined(separator: "  ")
        return [s.paint(String(repeating: "─", count: f.width), Theme.border),
                TextWidth.spread(left, s.paint(TextWidth.truncate(busy, to: max(0, f.width / 3)), Theme.faint) + " ", width: f.width - 1)]
    }
}

/// Writes frames, redrawing only rows (and, for pixel views, cells) that changed.
struct AppScreen {
    private var rows: [String] = []
    private var width = 0
    private var pixels: HalfBlockFrame?
    private var pixelRow = 0

    mutating func reset() {
        rows = []
        pixels = nil
    }

    /// A short note in place of the app while the window is too small, drawn once per size.
    mutating func tooSmall(columns: Int, rows height: Int, styler s: Styler) -> String {
        let note = "\u{0}small \(columns)x\(height)"
        guard rows != [note] else { return "" }
        rows = [note]
        pixels = nil
        let need = "\(DreadApp.minimumSize.columns)×\(DreadApp.minimumSize.rows)"
        let lines = ["dread needs a window at least \(need).", "This one is \(columns)×\(height). q quits."]
        return Styler.reset + TerminalControl.clearScreen + lines.enumerated().map { i, line in
            TerminalControl.moveTo(row: i + 1, column: 1) + s.paint(TextWidth.truncate(line, to: max(1, columns - 1)), i == 0 ? Theme.porcelain : Theme.faint)
        }.joined()
    }

    mutating func draw(tab: AppTab, view: AppView, frame f: AppFrame, styler s: Styler) -> String {
        let header = DreadApp.header(tab: tab, frame: f, styler: s)
        let footer = DreadApp.footer(view: view, frame: f, styler: s)
        let total = DreadApp.headerRows + f.height + DreadApp.footerRows
        var text = [String?](repeating: nil, count: total)
        for (i, line) in header.enumerated() { text[i] = line }
        var frame: HalfBlockFrame?
        switch view.body(f) {
        case .lines(let lines):
            for i in 0..<f.height { text[DreadApp.headerRows + i] = i < lines.count ? lines[i] : "" }
        case .pixels(let art, let above, let below):
            let top = min(above.count, f.height)
            for i in 0..<top { text[DreadApp.headerRows + i] = above[i] }
            if top + art.rows <= f.height {
                frame = art
                let start = DreadApp.headerRows + top + art.rows
                for i in 0..<(f.height - top - art.rows) { text[start + i] = i < below.count ? below[i] : "" }
            } else {
                // Art that doesn't fit is left out rather than drawn over the footer.
                for i in top..<f.height { text[DreadApp.headerRows + i] = "" }
            }
            if frame != nil, pixelRow != DreadApp.headerRows + top {
                pixels = nil
                pixelRow = DreadApp.headerRows + top
            }
        }
        for (i, line) in footer.enumerated() { text[total - DreadApp.footerRows + i] = line }

        var out = ""
        let resized = rows.count != total || width != f.width
        width = f.width
        if resized {
            out += Styler.reset + TerminalControl.clearScreen
            pixels = nil
        }
        var written: [String] = []
        for (i, line) in text.enumerated() {
            guard let line else { written.append("\u{0}pixels"); continue }
            let fitted = TextWidth.truncateStyled(line, to: f.width)
            if resized || i >= rows.count || rows[i] != fitted {
                out += TerminalControl.moveTo(row: i + 1, column: 1) + fitted + Styler.reset + "\u{1B}[K"
            }
            written.append(fitted)
        }
        if let frame {
            out += frame.update(from: pixels, styler: s, row: pixelRow + 1, column: 1)
        }
        rows = written
        pixels = frame
        return out
    }
}
