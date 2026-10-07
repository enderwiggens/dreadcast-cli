import Foundation
import DreadcastKit
import DreadTerminal

/// An animated radar loop at any size, for the Radar tab. The loop loads in
/// the background the first time it's drawn, reloads every five minutes and whenever the
/// size, range or place changes, and keeps the previous loop on screen meanwhile.
final class RadarPanel: @unchecked Sendable {
    struct Loop {
        let place: String
        let key: String
        let scene: RadarScene
        let frames: [Raster]
        let times: [Date]
        let loadedAt: Date
        var credit = "RainViewer"
        var delayed = false
    }

    /// What to draw: a frame of the loop, or a note while it loads or when it can't.
    enum Picture {
        case art(HalfBlockFrame)
        case note(String, failed: Bool)
    }

    /// Reload every few minutes for new frames (MRMS scans every two, RainViewer every
    /// ten); failures wait a minute to retry.
    static let reload: TimeInterval = 180
    static let retry: TimeInterval = 60

    private let lock = NSLock()
    private var loop: Loop?
    private var loading: String?
    private var failure: (key: String, message: String, at: Date)?
    private var shown: String?
    let palette: RadarPalette
    var range: Double
    var index = 0
    var paused = false
    var lastStep = Date()
    /// Tests supply loops directly instead of loading tiles.
    var fixture: ((_ place: Place, _ width: Int, _ rows: Int) -> Loop)?

    init(ctx: Context) {
        palette = ctx.config.palette
        range = Double(ctx.config.radarRange)
        paused = ctx.terminal.reduceMotion
    }

    var hints: [(String, String)] { [("space", paused ? "play" : "pause"), ("←/→", "step"), ("+/−", "range")] }

    /// The current frame at `width` × `rows` cells, advancing the animation.
    func picture(_ f: AppFrame, width: Int, rows: Int) -> Picture {
        let place = Context.placeKey(f.place)
        let key = "\(place) \(width)x\(rows)x\(range)"
        if let fixture, lock.withLock({ loop?.key }) != key { lock.withLock { loop = fixture(f.place, width, rows) } }
        let (current, pending, problem) = lock.withLock { (loop, loading, failure) }
        let due = current?.key != key || Date().timeIntervalSince(current?.loadedAt ?? .distantPast) > Self.reload
        let waiting = problem.map { $0.key == key && Date().timeIntervalSince($0.at) < Self.retry } ?? false
        if due, pending == nil, !waiting, fixture == nil { load(f, key: key, width: width, rows: rows) }
        // Another place's loop is never shown, even while this one loads, and a loop drawn
        // for another size waits for its replacement rather than being stretched.
        guard let current, current.place == place, let first = current.frames.first,
              first.width == width, first.height == rows * 2 else {
            if let failed = problem.flatMap({ $0.key == key ? $0.message : nil }) {
                return .note("Radar is unavailable: \(failed).", failed: true)
            }
            return .note("Loading radar…", failed: false)
        }
        // A new loop starts on its newest frame.
        let identity = current.key + "\(current.loadedAt.timeIntervalSince1970)"
        if shown != identity {
            shown = identity
            index = current.frames.count - 1
            lastStep = Date()
        }
        if index >= current.frames.count { index = current.frames.count - 1 }
        if !paused, Date().timeIntervalSince(lastStep) >= (index == current.frames.count - 1 ? 1.7 : 0.65) {
            index = (index + 1) % current.frames.count
            lastStep = Date()
        }
        let strikes = f.snapshot.lightning?.value?.current(at: f.ctx.now) ?? []
        return .art(HalfBlockFrame(raster: current.frames[index],
                                   overlays: current.scene.overlays(placeName: f.place.name, strikes: strikes, now: f.ctx.now)))
    }

    /// The frame's time, a dot per frame, then the range.
    func timeline(_ f: AppFrame) -> String {
        let s = f.ctx.styler
        guard let loop = lock.withLock({ loop }), !loop.times.isEmpty else { return "" }
        let time = index < loop.times.count ? f.fmt.time(loop.times[index]) : "--"
        let dots = (0..<loop.frames.count).map { s.paint("●", $0 == index ? f.ctx.highlight : Theme.faint) }.joined()
        let rangeText = "\(Int(f.ctx.units.distance(miles: range).rounded())) \(f.ctx.units.distanceUnit)"
        return s.paint("◀ ", f.ctx.highlight) + time + " " + dots + s.paint(" ▶", f.ctx.highlight)
            + s.paint("  \(rangeText)\(paused ? " · paused" : "")", Theme.mist)
    }

    /// The reflectivity scale in the palette's colors.
    func legend(_ f: AppFrame) -> String {
        let s = f.ctx.styler
        let ramp = [18.0, 24, 30, 36, 42, 48, 54, 60, 66].map { s.paint("█", RGB(hex: palette.rgb(dbz: $0))) }.joined()
        return "dBZ " + ramp + s.paint(" 18 → 65+", Theme.faint)
    }

    /// How old the newest frame is, called out when the source says it's late.
    func age(_ f: AppFrame) -> String {
        guard let loop = lock.withLock({ loop }), let latest = loop.times.last else { return "" }
        return (loop.delayed ? "radar delayed · " : "latest frame ") + Formatter.ago(latest, now: Date())
    }

    /// Whose radar is showing, such as NOAA MRMS or RainViewer.
    var credit: String { lock.withLock { loop?.credit } ?? "RainViewer" }

    private func load(_ f: AppFrame, key: String, width: Int, rows: Int) {
        lock.withLock { loading = key }
        let ctx = f.ctx, place = f.place, placeKey = Context.placeKey(f.place), range = range, palette = palette
        Task.detached { [weak self] in
            var result: Loop?
            var problem = "unknown error"
            let viewport = RadarViewport(center: place.coordinate, rangeMiles: range, width: width, height: rows * 2)
            do {
                let loop = try await ctx.radarLoop(for: place, viewport: viewport, frames: 8)
                let scene = RadarScene(viewport: viewport, palette: palette, minimumDBZ: 15, units: ctx.units,
                                       style: ctx.mapStyle, highlight: ctx.highlight)
                let base = scene.base()
                result = Loop(place: placeKey, key: key, scene: scene, frames: loop.fields.map { scene.compose(base: base, field: $0) },
                              times: loop.fields.map(\.time), loadedAt: Date(), credit: loop.credit, delayed: loop.delayed)
            } catch {
                problem = error.localizedDescription.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            guard let self else { return }
            self.lock.withLock {
                if let result { self.loop = result; self.failure = nil } else { self.failure = (key, problem, Date()) }
                self.loading = nil
            }
        }
    }

    func handle(_ key: Key) -> Bool {
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
