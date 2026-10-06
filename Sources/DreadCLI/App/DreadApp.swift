import Foundation
import DreadcastKit
import DreadTerminal

/// The app's views, one tab each.
enum AppTab: Int, CaseIterable, Sendable {
    case now, systems, radar, forecast, alerts, outlook, lightning, scene

    var title: String {
        switch self {
        case .now: "Now"
        case .systems: "Systems"
        case .radar: "Radar"
        case .forecast: "Forecast"
        case .alerts: "Alerts"
        case .outlook: "Outlook"
        case .lightning: "Lightning"
        case .scene: "Scene"
        }
    }

    static func named(_ name: String) -> AppTab? {
        let key = name.lowercased()
        if let number = Int(key), let tab = AppTab(rawValue: number - 1) { return tab }
        return allCases.first { $0.title.lowercased() == key } ?? (key == "top" ? .systems : nil)
    }
}

/// What a view draws in the body: text, or pixels with text beneath them.
enum AppBody {
    case lines([String])
    case pixels(HalfBlockFrame, below: [String])
}

/// Everything a view needs for one frame.
struct AppFrame {
    let ctx: Context
    let place: Place
    let snapshot: TopCommand.Snapshot
    let width: Int
    let height: Int
    let elapsed: Double

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
}

/// `dread` in an interactive terminal (and `dread top`): one full-screen app with a tab
/// for each view. Every view reads the same live data, which each source refreshes on
/// its own schedule; nothing is fetched twice when you switch tabs.
enum DreadApp {
    static let headerRows = 3
    static let footerRows = 2

    static func run(_ ctx: Context, tab start: AppTab) async throws -> ExitCode {
        let place = try await ctx.resolveLocation()
        guard let raw = RawTerminal(alternateScreen: true) else {
            return ctx.fail("Couldn’t take over the terminal.", code: .unavailable)
        }
        defer { raw.restore() }
        ctx.inApp = true
        _ = ctx.tiles   // created up front; views load radar tiles in the background

        let state = TopCommand.State()
        let configured = Credentials.xweather(environment: ctx.environment) != nil
        state.with { $0.lightningConfigured = configured }
        let views: [AppTab: AppView] = [
            .now: NowView(), .systems: SystemsView(), .radar: RadarView(ctx: ctx), .forecast: ForecastView(),
            .alerts: AlertsView(), .outlook: OutlookView(), .lightning: LightningView(), .scene: SceneView(ctx: ctx),
        ]
        var tab = start
        var screen = AppScreen()
        let started = Date()
        var lastDraw = Date.distantPast
        Console.write(TerminalControl.clearScreen)

        func frame() -> AppFrame {
            let size = TerminalInfo.windowSize() ?? (ctx.terminal.columns, ctx.terminal.rows)
            return AppFrame(ctx: ctx, place: place, snapshot: state.snapshot, width: max(60, size.0),
                            height: max(4, max(12, size.1) - headerRows - footerRows), elapsed: Date().timeIntervalSince(started))
        }

        while true {
            ctx.refreshClock()
            if tab == .outlook { state.with { $0.wantsOutlook = true } }
            TopCommand.schedule(ctx: ctx, place: place, state: state)
            let view = views[tab]!
            if Date().timeIntervalSince(lastDraw) >= view.interval {
                let current = frame()
                Console.write(screen.draw(tab: tab, view: view, frame: current, styler: ctx.styler))
                lastDraw = Date()
            }
            guard let key = raw.readKey(timeout: min(0.2, view.interval)) else { continue }
            var redraw = true
            switch key {
            case .character("q"), .character("Q"), .escape, .interrupt:
                return .ok
            case .tab:
                tab = AppTab(rawValue: (tab.rawValue + 1) % AppTab.allCases.count)!
                screen.reset()
            case .backTab:
                tab = AppTab(rawValue: (tab.rawValue + AppTab.allCases.count - 1) % AppTab.allCases.count)!
                screen.reset()
            case .character(let c) where c.isNumber:
                if let number = c.wholeNumberValue, let chosen = AppTab(rawValue: number - 1), chosen != tab {
                    tab = chosen
                    screen.reset()
                }
            case .character("r"), .character("R"):
                state.with { $0.lastFetch = [:] }
                ctx.cache.remove(key: "alerts-\(Context.placeKey(place))")
            default:
                redraw = view.handle(key, frame: frame())
            }
            if redraw { lastDraw = .distantPast }
        }
    }

    // MARK: Frame

    static func header(tab: AppTab, frame f: AppFrame, styler s: Styler) -> [String] {
        let clock = Date()
        let alerts = f.snapshot.alerts?.value ?? []
        var right = s.paint(f.fmt.time(clock) + " " + f.fmt.zoneAbbreviation(clock), Theme.faint) + " "
        if let worst = alerts.sorted(by: WeatherAlert.threatOrder).first {
            let badge = " ▲ \(alerts.count == 1 ? worst.event.uppercased() : "\(alerts.count) ALERTS") "
            right = s.paint(badge, TextStyle(foreground: Theme.midnight, background: NowCommand.alertColor(worst), bold: true)) + "  " + right
        }
        let title = TextWidth.spread(" " + s.paint("DREADCAST", Theme.porcelain, bold: true) + s.paint("  ·  ", Theme.faint) + f.place.name,
                                     right, width: f.width)
        return [title, tabs(active: tab, alerts: alerts, width: f.width, styler: s), s.paint(String(repeating: "─", count: f.width), Theme.border)]
    }

    /// The tab bar. When every name doesn't fit, other tabs show only their numbers.
    static func tabs(active: AppTab, alerts: [WeatherAlert], width: Int, styler s: Styler) -> String {
        let worst = alerts.sorted(by: WeatherAlert.threatOrder).first
        func bar(named: Bool) -> String {
            var line = " "
            for candidate in AppTab.allCases {
                let count = candidate == .alerts && !alerts.isEmpty ? " \(alerts.count)" : ""
                if candidate == active {
                    line += s.paint(" \(candidate.rawValue + 1) \(candidate.title)\(count) ", TextStyle(foreground: Theme.midnight, background: Theme.lamp, bold: true))
                } else {
                    let color = worst.map { candidate == .alerts ? NowCommand.alertColor($0) : Theme.mist } ?? Theme.mist
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
        let keys = [("tab", "next"), ("1–8", "views")] + view.hints + [("r", "refresh"), ("q", "quit")]
        let busy = f.snapshot.inFlight.isEmpty ? "" : "updating \(f.snapshot.inFlight.sorted().joined(separator: ", "))…"
        let left = " " + keys.map { s.paint($0.0, Theme.lamp) + " " + s.paint($0.1, Theme.mist) }.joined(separator: "  ")
        return [s.paint(String(repeating: "─", count: f.width), Theme.border),
                TextWidth.spread(left, s.paint(TextWidth.truncate(busy, to: max(0, f.width / 3)), Theme.faint) + " ", width: f.width - 1)]
    }
}

/// Writes frames, redrawing only rows (and, for pixel views, cells) that changed.
struct AppScreen {
    private var rows: [String] = []
    private var width = 0
    private var pixels: HalfBlockFrame?

    mutating func reset() {
        rows = []
        pixels = nil
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
        case .pixels(let art, let below):
            frame = art
            let start = DreadApp.headerRows + art.rows
            for i in 0..<max(0, f.height - art.rows) { text[start + i] = i < below.count ? below[i] : "" }
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
            out += frame.update(from: pixels, styler: s, row: DreadApp.headerRows + 1, column: 1)
        }
        rows = written
        pixels = frame
        return out
    }
}
