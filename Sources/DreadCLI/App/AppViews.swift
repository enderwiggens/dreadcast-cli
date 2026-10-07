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

/// The quick look: your scene, conditions, alerts, the next two hours and five days.
final class NowView: ScrollingView {
    override var interval: Double { 1 }
    /// When the scene first appeared, for the wordmark that greets you.
    var greeted: Double?

    override func content(_ f: AppFrame) -> [String] {
        let snapshot = f.snapshot
        guard let weather = snapshot.weather, let alerts = snapshot.alerts ?? (f.place.isUnitedStates ? nil : .failure("")) else {
            return Self.loading("conditions", f)
        }
        // The banner appears once the body has room for it and everything below it.
        let since = f.elapsed - (greeted ?? f.elapsed)
        if greeted == nil { greeted = f.elapsed }
        return NowCommand.pretty(place: f.place, weather: weather, alerts: alerts,
                                 lightning: snapshot.lightningConfigured ? snapshot.lightning : nil,
                                 nowcast: snapshot.nowcast?.value, ctx: f.ctx, width: Self.textWidth(f, maximum: 96),
                                 rows: f.height + 5, sceneTime: (f.elapsed / 4).rounded(.down) * 4,
                                 wordmark: Wordmark.opacity(after: since))
    }
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
                    "  Add credentials with " + st.paint("dread auth xweather", Theme.lamp) + ", then strikes appear here,",
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

/// The animated loop, loaded in the background the first time the tab opens.
final class RadarView: AppView, @unchecked Sendable {
    struct Loop {
        let place: String
        let key: String
        let scene: RadarScene
        let frames: [Raster]
        let times: [Date]
        let loadedAt: Date
    }

    /// RainViewer publishes a frame every ten minutes; failures wait a minute to retry.
    static let reload: TimeInterval = 300
    static let retry: TimeInterval = 60

    private let lock = NSLock()
    private var loop: Loop?
    private var loading: String?
    private var failure: (key: String, message: String, at: Date)?
    private var shown: String?
    private let palette: RadarPalette
    var range: Double
    var index = 0
    var paused = false
    var lastStep = Date()
    let reduceMotion: Bool

    init(ctx: Context) {
        palette = ctx.config.palette
        range = Double(ctx.config.radarRange)
        reduceMotion = ctx.terminal.reduceMotion
        paused = reduceMotion
    }

    var interval: Double { 0.1 }
    var hints: [(String, String)] { [("space", paused ? "play" : "pause"), ("←/→", "step"), ("+/−", "range")] }

    static let hudRows = 3

    func body(_ f: AppFrame) -> AppBody {
        if let note = ScrollingView.needsColor(f) { return .lines(note) }
        let rows = max(4, f.height - Self.hudRows)
        let place = Context.placeKey(f.place)
        let key = "\(place) \(f.width)x\(rows)x\(range)"
        let (current, pending, problem) = lock.withLock { (loop, loading, failure) }
        // Load on first view and when the size or range changes, then keep the loop fresh.
        // The previous loop stays on screen until the next one is ready.
        let due = current?.key != key || Date().timeIntervalSince(current?.loadedAt ?? .distantPast) > Self.reload
        let waiting = problem.map { $0.key == key && Date().timeIntervalSince($0.at) < Self.retry } ?? false
        if due, pending == nil, !waiting { load(f, key: key, rows: rows) }
        // Another place's loop is never shown, even while this one loads.
        guard let current, current.place == place, !current.frames.isEmpty else {
            let s = f.ctx.styler
            let failed = problem.flatMap { $0.key == key ? $0.message : nil }
            return .lines(["", "  " + (failed.map { s.paint("Radar is unavailable: \($0).", Theme.advisory) } ?? s.paint("Loading radar…", Theme.faint))])
        }
        // A new loop starts on its newest frame.
        if shown != current.key + "\(current.loadedAt.timeIntervalSince1970)" {
            shown = current.key + "\(current.loadedAt.timeIntervalSince1970)"
            index = current.frames.count - 1
            lastStep = Date()
        }
        if index >= current.frames.count { index = current.frames.count - 1 }
        if !paused, Date().timeIntervalSince(lastStep) >= (index == current.frames.count - 1 ? 1.7 : 0.65) {
            index = (index + 1) % current.frames.count
            lastStep = Date()
        }
        let strikes = f.snapshot.lightning?.value?.current(at: f.ctx.now) ?? []
        let art = HalfBlockFrame(raster: current.frames[index], overlays: current.scene.overlays(placeName: f.place.name, strikes: strikes, now: f.ctx.now))
        return .pixels(art, below: hud(current, f))
    }

    private func hud(_ loop: Loop, _ f: AppFrame) -> [String] {
        let s = f.ctx.styler
        let time = index < loop.times.count ? f.fmt.time(loop.times[index]) : "--"
        let dots = (0..<loop.frames.count).map { s.paint("●", $0 == index ? Theme.lamp : Theme.faint) }.joined()
        let ramp = [18.0, 24, 30, 36, 42, 48, 54, 60, 66].map { s.paint("█", RGB(hex: palette.rgb(dbz: $0))) }.joined()
        let rangeText = "\(Int(f.ctx.units.distance(miles: range).rounded())) \(f.ctx.units.distanceUnit)"
        return [
            "  " + s.paint("◀ ", Theme.lamp) + time + " " + dots + s.paint(" ▶", Theme.lamp) + s.paint("   \(rangeText) · \(palette.title)\(paused ? " · paused" : "")", Theme.mist),
            "  dBZ " + ramp + s.paint(" 18 → 65+", Theme.faint),
            "  " + s.paint("RainViewer · Natural Earth · latest frame \(Formatter.ago(loop.times.last ?? f.ctx.now, now: Date()))", Theme.faint),
        ]
    }

    private func load(_ f: AppFrame, key: String, rows: Int) {
        lock.withLock { loading = key }
        let ctx = f.ctx, place = f.place, placeKey = Context.placeKey(f.place), width = f.width, range = range, palette = palette
        Task.detached { [weak self] in
            let manifest = await ctx.manifest()
            var result: Loop?
            var problem = manifest.error ?? "unknown error"
            if let radar = manifest.value {
                let viewport = RadarViewport(center: place.coordinate, rangeMiles: range, width: width, height: rows * 2)
                let scene = RadarScene(viewport: viewport, palette: palette, minimumDBZ: 15, units: ctx.units)
                let base = scene.base()
                let fields = await RadarLoader(http: ctx.http, store: ctx.tiles).fields(manifest: radar, frames: radar.recent(8), viewport: viewport)
                if fields.isEmpty {
                    problem = "no frames right now"
                } else {
                    result = Loop(place: placeKey, key: key, scene: scene, frames: fields.map { scene.compose(base: base, field: $0) },
                                  times: fields.map(\.time), loadedAt: Date())
                }
            }
            guard let self else { return }
            self.lock.withLock {
                if let result { self.loop = result; self.failure = nil } else { self.failure = (key, problem, Date()) }
                self.loading = nil
            }
        }
    }

    func handle(_ key: Key, frame f: AppFrame) -> Bool {
        let count = lock.withLock { loop?.frames.count ?? 0 }
        switch key {
        case .character(" "): paused.toggle()
        case .right where count > 0: paused = true; index = (index + 1) % count
        case .left where count > 0: paused = true; index = (index - 1 + count) % count
        case .character("+"), .character("="), .character("-"), .character("_"):
            let ranges = Config.ranges.map(Double.init)
            let current = ranges.indices.min { abs(ranges[$0] - range) < abs(ranges[$1] - range) } ?? 1
            let zoomIn = key == .character("+") || key == .character("=")
            range = ranges[zoomIn ? max(0, current - 1) : min(ranges.count - 1, current + 1)]
        default: return false
        }
        return true
    }
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
            if let period = fixedPeriod { fixedPeriod = period == .night ? nil : period.next } else { fixedPeriod = .dawn }
        case .character(" "):
            if paused { offset = f.elapsed - frozen } else { frozen = f.elapsed - offset }
            paused.toggle()
        default: return false
        }
        return true
    }
}
