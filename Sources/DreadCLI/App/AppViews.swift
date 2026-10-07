import Foundation
import DreadcastKit
import DreadTerminal

// The app's views. Each draws one tab's body from the shared snapshot, reusing the same
// renderers as the one-shot commands so nothing is drawn two ways.

/// A text view that scrolls when its content is taller than the body.
class ScrollingView: AppView {
    var offset = 0
    var lastCount = 0
    var lastHeight = 0
    var interval: Double { 1 }
    var hints: [(String, String)] { lastCount > lastHeight ? [("↑/↓", "scroll")] : [] }

    func content(_ f: AppFrame) -> [String] { [] }

    func body(_ f: AppFrame) -> AppBody {
        let all = content(f)
        lastCount = all.count
        lastHeight = f.height
        offset = min(offset, max(0, all.count - f.height))
        return .lines(Array(all.dropFirst(offset).prefix(f.height)))
    }

    func placeChanged() { offset = 0 }

    func handle(_ key: Key, frame f: AppFrame) -> Bool {
        let page = max(1, f.height - 2)
        switch key {
        case .up, .character("k"): offset = max(0, offset - 1)
        case .down, .character("j"): offset += 1
        case .pageUp: offset = max(0, offset - page)
        case .pageDown, .character(" "): offset += page
        case .home, .character("g"): offset = 0
        case .end, .character("G"): offset = Int.max / 2
        default: return false
        }
        return true
    }

    static func loading(_ what: String, _ f: AppFrame) -> [String] {
        ["", "  " + f.ctx.styler.paint("Loading \(what)…", Theme.faint)]
    }

    /// Pixel art needs 256 colors; with fewer (or NO_COLOR), say so instead of drawing
    /// uncolored blocks.
    static func needsColor(_ f: AppFrame) -> [String]? {
        guard f.ctx.styler.mode < .ansi256 else { return nil }
        return ["", "  This view draws pixel art, which needs a terminal with 256 colors or more.",
                "  Colors are off here (NO_COLOR, --no-color, or a basic terminal). The other views still work."]
    }

    /// The width text views lay themselves out in.
    static func textWidth(_ f: AppFrame, maximum: Int = 100) -> Int { min(f.width - 1, maximum) }
}

// MARK: Now

/// Home, laid out like the Dreadcast window: the scene as a short header, the readings,
/// then live radar filling the rest, with the timeline and the next few days beneath it.
/// Without room for the radar, or without 256 colors, it shows the quick look's text.
final class NowView: AppView {
    let radar: RadarPanel
    private var showingRadar = true
    private var sceneCache: (key: String, lines: [String])?

    init(ctx: Context) { radar = RadarPanel(ctx: ctx) }

    var interval: Double { 0.1 }
    var hints: [(String, String)] { showingRadar ? [("+/−", "range"), ("space", radar.paused ? "play" : "pause")] : [] }

    static let sceneRows = 6
    static let minimumRadarRows = 8
    /// Radar comes first: the scene shows only while the radar keeps at least this many rows.
    static let radarRowsWithScene = 14
    static let footerRows = 2

    func body(_ f: AppFrame) -> AppBody {
        let snapshot = f.snapshot
        guard let weather = snapshot.weather, let alerts = snapshot.alerts ?? (f.place.isUnitedStates ? nil : .failure("")) else {
            return .lines(ScrollingView.loading("conditions", f))
        }
        guard f.ctx.styler.mode >= .ansi256 else { return text(f, weather: weather, alerts: alerts) }
        let s = f.ctx.styler
        let ctx = f.ctx, report = weather.value, fmt = f.fmt, width = f.width - 1
        let lightning = snapshot.lightningConfigured ? snapshot.lightning : nil

        var readings = [""] + NowCommand.conditionsLines(report: report, weather: weather, fmt: fmt, ctx: ctx, width: width)
        readings += NowCommand.alertSummary(place: f.place, alerts: alerts, fmt: fmt, ctx: ctx, width: width)
        if let report { readings.append(NowCommand.nextTwoHours(report: report, nowcast: snapshot.nowcast?.value, fmt: fmt, ctx: ctx)) }
        if let lightning { readings.append(NowCommand.lightningLine(lightning, fmt: fmt, ctx: ctx)) }
        readings.append("")

        // The scene goes first when space is short; then the radar, for the text layout.
        var scene = sceneLines(f, alerts: alerts, report: report)
        var rows = f.height - scene.count - readings.count - Self.footerRows
        if rows < Self.radarRowsWithScene, !scene.isEmpty {
            scene = []
            rows = f.height - readings.count - Self.footerRows
        }
        guard rows >= Self.minimumRadarRows else { return text(f, weather: weather, alerts: alerts) }
        showingRadar = true
        let picture = radar.picture(f, width: f.width, rows: rows)
        let below = [
            TextWidth.spread("  " + radar.timeline(f), forecastRow(report, f, room: width - 44), width: width),
            TextWidth.spread("  " + radar.legend(f), s.paint(sources(f, lightning: lightning != nil) + "  " + radar.age(f), Theme.faint), width: width),
        ]
        switch picture {
        case .art(let art):
            return .pixels(art, above: scene + readings, below: below)
        case .note(let note, let failed):
            var waiting = [String](repeating: "", count: rows)
            waiting[rows / 2] = TextWidth.pad("", to: max(0, (f.width - TextWidth.of(note)) / 2)) + s.paint(note, failed ? Theme.advisory : Theme.faint)
            return .lines(scene + readings + waiting + below)
        }
    }

    /// The quick look as text, for small windows and terminals without 256 colors.
    private func text(_ f: AppFrame, weather: Fetched<WeatherReport>, alerts: Fetched<[WeatherAlert]>) -> AppBody {
        showingRadar = false
        let snapshot = f.snapshot
        let lines = NowCommand.pretty(place: f.place, weather: weather, alerts: alerts,
                                      lightning: snapshot.lightningConfigured ? snapshot.lightning : nil,
                                      nowcast: snapshot.nowcast?.value, ctx: f.ctx, width: ScrollingView.textWidth(f, maximum: 96),
                                      rows: f.height + 5, sceneTime: (f.elapsed / 4).rounded(.down) * 4)
        return .lines(Array(lines.prefix(f.height)))
    }

    /// The scene header, repainted only when it changes (every few seconds).
    private func sceneLines(_ f: AppFrame, alerts: Fetched<[WeatherAlert]>, report: WeatherReport?) -> [String] {
        let time = (f.elapsed / 4).rounded(.down) * 4
        let key = "\(Context.placeKey(f.place)) \(f.width) \(time) \(alerts.value?.count ?? -1) \(ScenePeriod.at(f.ctx.now, timeZone: f.zone))"
        if let cached = sceneCache, cached.key == key { return cached.lines }
        let lines = NowCommand.sceneStrip(place: f.place, alerts: alerts, report: report, ctx: f.ctx,
                                          width: f.width, rows: Self.sceneRows, sceneTime: time)
        sceneCache = (key, lines)
        return lines
    }

    /// Beside the timeline, as the app's header forecast: days, the coming hours, or nothing.
    private func forecastRow(_ report: WeatherReport?, _ f: AppFrame, room: Int) -> String {
        switch ForecastRow.named(f.ctx.config.forecast) ?? .days {
        case .days: days(report, f, room: room)
        case .hourly: hours(report, f, room: room)
        case .off: ""
        }
    }

    /// As many of the coming hours as fit: temperature and chance of rain.
    private func hours(_ report: WeatherReport?, _ f: AppFrame, room: Int) -> String {
        guard let report else { return "" }
        let s = f.ctx.styler, fmt = f.fmt
        var parts: [String] = []
        for hour in report.hours(from: f.ctx.now, count: 12) {
            let rain = Int(hour.precipitationProbability ?? 0)
            let part = s.paint(fmt.hour(hour.time), Theme.mist) + " " + s.paint(fmt.temperature(hour.temperature), ForecastCommand.temperatureColor(hour.temperature ?? 0, units: f.ctx.units))
                + " " + s.paint("\(rain)%", ForecastCommand.rainColor(Double(rain)))
            guard TextWidth.of((parts + [part]).joined(separator: "  ")) <= room else { break }
            parts.append(part)
        }
        return parts.joined(separator: "  ")
    }

    /// As many of the coming days as fit in `room` cells: low–high and chance of rain.
    private func days(_ report: WeatherReport?, _ f: AppFrame, room: Int) -> String {
        guard let report else { return "" }
        let s = f.ctx.styler, fmt = f.fmt
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = fmt.timeZone
        var parts: [String] = []
        for day in DayRows.upcoming(report, from: f.ctx.now, count: 5) {
            let name = calendar.isDate(day.date, inSameDayAs: f.ctx.now) ? "Today" : fmt.weekday(day.date)
            let rain = Int(day.precipitationProbability ?? 0)
            let part = s.paint(name, Theme.mist) + " " + s.paint(fmt.temperature(day.low), Theme.information) + s.paint("–", Theme.faint)
                + s.paint(fmt.temperature(day.high), Theme.warning) + " " + s.paint("\(rain)%", ForecastCommand.rainColor(Double(rain)))
            guard TextWidth.of((parts + [part]).joined(separator: "   ")) <= room else { break }
            parts.append(part)
        }
        return parts.joined(separator: "   ")
    }

    private func sources(_ f: AppFrame, lightning: Bool) -> String {
        var names = ["OPEN-METEO"]
        if f.place.isUnitedStates { names.append("NWS") }
        names.append("RAINVIEWER")
        if lightning { names.append("XWEATHER") }
        return names.joined(separator: " · ")
    }

    func handle(_ key: Key, frame f: AppFrame) -> Bool { showingRadar && radar.handle(key) }
}

// MARK: Systems

/// Weather systems near you, listed like processes and sorted by threat.
final class SystemsView: AppView {
    var selected = 0
    var interval: Double { 1 }
    var hints: [(String, String)] { [("↑/↓", "select")] }

    func body(_ f: AppFrame) -> AppBody {
        let result = TopCommand.systemsLines(ctx: f.ctx, place: f.place, snapshot: f.snapshot, selected: selected,
                                             width: f.width, height: f.height)
        selected = result.selected
        return .lines(result.lines)
    }

    func handle(_ key: Key, frame f: AppFrame) -> Bool {
        switch key {
        case .up, .character("k"): selected = max(0, selected - 1)
        case .down, .character("j"): selected += 1
        default: return false
        }
        return true
    }

    func placeChanged() { selected = 0 }
}

// MARK: Places

/// Every watched place at a glance. Enter shows the highlighted place in full.
final class PlacesView: AppView {
    var highlighted = 0
    private var choice: Int?
    var interval: Double { 1 }
    var hints: [(String, String)] { [("↑/↓", "select"), ("enter", "show")] }

    func body(_ f: AppFrame) -> AppBody {
        let s = f.ctx.styler
        let watched = f.watched
        highlighted = min(max(0, highlighted), watched.count - 1)
        var lines = ["", PlaceRows.header(styler: s, width: f.width)]
        for (i, w) in watched.enumerated() {
            lines.append(PlaceRows.line(w.reading, ctx: f.ctx, width: f.width, highlighted: i == highlighted, viewing: i == f.selectedIndex))
        }
        lines.append("")

        // The highlighted place's alerts, in brief.
        let w = watched[highlighted]
        lines.append("  " + s.paint(w.saved.name, Theme.porcelain, bold: true) + s.paint("  ·  " + w.saved.place.name, Theme.mist))
        let fmt = Formatter(units: f.ctx.units, timeZone: w.snapshot.weather?.value?.timeZone ?? f.ctx.timeZone(for: w.saved.place))
        let width = ScrollingView.textWidth(f, maximum: 96)
        switch PlaceRows.alertState(w.reading) {
        case .active:
            let alerts = (w.snapshot.alerts?.value ?? []).sorted(by: WeatherAlert.threatOrder)
            for alert in alerts.prefix(3) { lines += NowCommand.alertLines(alert, fmt: fmt, ctx: f.ctx, width: width).prefix(1) }
            if alerts.count > 3 { lines.append("  " + s.paint("+\(alerts.count - 3) more on the Alerts tab", Theme.mist)) }
        case .clear: lines.append("  " + s.paint("No active alerts for this location.", Theme.mint))
        case .unknown: lines.append("  " + s.paint("Alerts are unavailable right now. This is not an all-clear.", Theme.advisory))
        case .loading: lines.append("  " + s.paint("Loading alerts…", Theme.faint))
        case .notCovered: lines.append("  " + s.paint("Official alerts are available for US locations.", Theme.faint))
        }
        lines.append("")
        lines.append("  " + s.paint("Other places refresh alerts every 2 minutes and conditions every 10; the highlighted row also", Theme.faint))
        lines.append("  " + s.paint("checks radar for rain. Enter shows a place in full. Save more with dread places add.", Theme.faint))
        return .lines(Array(lines.prefix(f.height)))
    }

    func handle(_ key: Key, frame f: AppFrame) -> Bool {
        switch key {
        case .up, .character("k"): highlighted = max(0, highlighted - 1)
        case .down, .character("j"): highlighted = min(f.watched.count - 1, highlighted + 1)
        case .enter: choice = highlighted
        default: return false
        }
        return true
    }

    /// The place chosen with Enter, once.
    func takeChoice() -> Int? {
        defer { choice = nil }
        return choice
    }
}

// MARK: Forecast, alerts, outlook, lightning

final class ForecastView: ScrollingView {
    override func content(_ f: AppFrame) -> [String] {
        guard let fetched = f.snapshot.weather else { return Self.loading("the forecast", f) }
        guard let report = fetched.value else {
            return ["", "  " + f.ctx.styler.paint("The forecast is unavailable: \(fetched.error ?? "unknown error").", Theme.advisory)]
        }
        let width = Self.textWidth(f, maximum: 130)
        let hours = report.hours(from: f.ctx.now, count: max(6, min(24, (width - 12) / 5)))
        return ForecastCommand.pretty(place: f.place, report: report, hours: hours, days: Array(report.daily.prefix(7)),
                                      fetched: fetched, fmt: Formatter(units: f.ctx.units, timeZone: report.timeZone), ctx: f.ctx, width: width)
    }
}

final class AlertsView: ScrollingView {
    override func content(_ f: AppFrame) -> [String] {
        guard f.place.isUnitedStates else {
            return ["", "  " + f.ctx.styler.paint("Official alerts are available for US locations.", Theme.faint)]
        }
        guard let fetched = f.snapshot.alerts else { return Self.loading("alerts", f) }
        guard let alerts = fetched.value else {
            return ["", "  " + f.ctx.styler.paint("Alerts are unavailable: \(fetched.error ?? "unknown error"). This is not an all-clear.", Theme.advisory)]
        }
        return AlertsCommand.prettyLines(alerts.sorted(by: WeatherAlert.threatOrder), place: f.place, fetched: fetched,
                                         fmt: f.fmt, ctx: f.ctx, width: Self.textWidth(f, maximum: 96))
    }
}

final class OutlookView: ScrollingView {
    override func content(_ f: AppFrame) -> [String] {
        let s = f.snapshot
        guard let solar = s.solar, let quakes = s.quakes, let aurora = s.aurora, let hazards = s.hazards else {
            return Self.loading("the outlook", f)
        }
        let showers = Array(MeteorCalendar.upcoming(at: f.ctx.now, timeZone: f.zone).prefix(2))
        return OutlookCommand.pretty(place: f.place, solar: solar, quakes: quakes, aurora: aurora, hazards: hazards,
                                     weather: s.weather?.value, showers: showers, fmt: f.fmt, ctx: f.ctx,
                                     width: Self.textWidth(f, maximum: 96))
    }
}

final class LightningView: ScrollingView {
    override func content(_ f: AppFrame) -> [String] {
        let st = f.ctx.styler
        guard f.snapshot.lightningConfigured else {
            return ["", "  " + st.paint("LIGHTNING", Theme.porcelain, bold: true), "",
                    "  Lightning uses your own Xweather account.",
                    "  Add credentials with " + st.paint("dread auth xweather", f.ctx.highlight) + ", then strikes appear here,",
                    "  on the Now and Radar tabs, and in Systems."]
        }
        guard let fetched = f.snapshot.lightning else { return Self.loading("lightning", f) }
        guard let snapshot = fetched.value else {
            return ["", "  " + st.paint("Lightning is unavailable: \(fetched.error ?? "unknown error").", Theme.advisory)]
        }
        return LightningCommand.pretty(place: f.place, snapshot: snapshot, fetched: fetched, fmt: f.fmt, ctx: f.ctx,
                                       watching: true, width: f.width, height: f.height + 4)
    }
}

// MARK: Radar

/// The radar on its own, as large as the window allows, with the scale and controls.
final class RadarView: AppView {
    let panel: RadarPanel

    init(ctx: Context) { panel = RadarPanel(ctx: ctx) }

    var interval: Double { 0.1 }
    var hints: [(String, String)] { panel.hints }

    static let hudRows = 3

    func body(_ f: AppFrame) -> AppBody {
        if let note = ScrollingView.needsColor(f) { return .lines(note) }
        let s = f.ctx.styler
        switch panel.picture(f, width: f.width, rows: max(4, f.height - Self.hudRows)) {
        case .note(let text, let failed):
            return .lines(["", "  " + s.paint(text, failed ? Theme.advisory : Theme.faint)])
        case .art(let art):
            return .pixels(art, below: [
                "  " + panel.timeline(f) + s.paint(" · \(panel.palette.title)", Theme.mist),
                "  " + panel.legend(f),
                "  " + s.paint("RainViewer · Natural Earth · " + panel.age(f), Theme.faint),
            ])
        }
    }

    func handle(_ key: Key, frame f: AppFrame) -> Bool { panel.handle(key) }
}

// MARK: Scene

/// The full scene with the readings beneath it.
final class SceneView: AppView {
    var scene: SceneID?
    var fixedPeriod: ScenePeriod?
    var paused = false
    var frozen = 0.0
    var offset = 0.0
    let reduceMotion: Bool

    init(ctx: Context) { reduceMotion = ctx.terminal.reduceMotion }

    var interval: Double { reduceMotion ? 1 : 0.11 }
    var hints: [(String, String)] { [("←/→", "scene"), ("t", "time of day"), ("space", paused ? "play" : "pause")] }

    func body(_ f: AppFrame) -> AppBody {
        if let note = ScrollingView.needsColor(f) { return .lines(note) }
        let chosen = scene ?? SceneCommand.configuredScene(f.ctx, timeZone: f.zone)
        scene = chosen
        let period = fixedPeriod ?? ScenePeriod.at(f.ctx.now, timeZone: f.zone)
        let readings = SceneCommand.Readings(place: f.place, weather: f.snapshot.weather, alerts: f.place.isUnitedStates ? f.snapshot.alerts : nil)
        var below = [""] + SceneInfo.lines(scene: chosen, period: period, readings: readings, ctx: f.ctx, width: f.width)
        if f.height < below.count + 6 { below = [] }
        let rows = max(4, f.height - below.count)
        let time = paused ? frozen : f.elapsed - offset
        let raster = ScenePainter(scene: chosen, period: period, time: time, still: reduceMotion, moon: LunarPhase(at: f.ctx.now))
            .paint(width: f.width, height: rows * 2)
        return .pixels(HalfBlockFrame(raster: raster), below: below)
    }

    func handle(_ key: Key, frame f: AppFrame) -> Bool {
        let current = scene ?? .asteroid
        switch key {
        case .right, .character("n"): scene = current.adjacent(1)
        case .left, .character("p"): scene = current.adjacent(-1)
        case .character("t"), .up, .down:
            // auto → dusk → night → auto
            if let period = fixedPeriod {
                fixedPeriod = period == ScenePeriod.shown.last ? nil : period.next
            } else {
                fixedPeriod = ScenePeriod.shown.first
            }
        case .character(" "):
            if paused { offset = f.elapsed - frozen } else { frozen = f.elapsed - offset }
            paused.toggle()
        default: return false
        }
        return true
    }
}
