import Foundation
import DreadcastKit

/// The app's live data for one place. Each source refreshes on its own cadence in the
/// background and fails on its own; views read a snapshot of whatever has arrived.
enum LiveData {
    /// Everything the app has loaded for one place. Copied out under the lock for each render.
    struct Snapshot: Sendable {
        var weather: Fetched<WeatherReport>?
        var alerts: Fetched<[WeatherAlert]>?
        var lightning: Fetched<LightningSnapshot>?
        var nowcast: Fetched<Nowcast>?
        var severe: Fetched<Context.SevereRisk>?
        var tropical: Fetched<[TropicalStorm]>?
        var fires: Fetched<[Wildfire]>?
        var air: Fetched<AirQualityReading>?
        var hazards: Fetched<HazardSummary>?
        var quakes: Fetched<EarthquakeSnapshot>?
        var solar: Fetched<SolarOutlook>?
        var aurora: Fetched<AuroraReading>?
        var lightningConfigured = false
        /// Solar and aurora data load only once the Outlook tab has been opened.
        var wantsOutlook = false
        var lastFetch: [String: Date] = [:]
        var inFlight: Set<String> = []
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Snapshot()

        func with<T>(_ body: (inout Snapshot) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&data)
        }

        var snapshot: Snapshot { with { $0 } }
    }

    /// How often each source refreshes, in seconds.
    static let cadences: [(String, TimeInterval)] = [
        ("weather", 600), ("alerts", 120), ("lightning", 60), ("nowcast", 300), ("severe", 900),
        ("tropical", 900), ("fires", 300), ("air", 1800), ("hazards", 900), ("quakes", 300), ("solar", 600), ("aurora", 900)
    ]

    /// Starts every source that's due. `only` limits a place to some sources, for places
    /// watched in the background.
    static func schedule(ctx: Context, place: Place, state: State, only: Set<String>? = nil) {
        let now = Date()
        for (name, cadence) in cadences where only?.contains(name) ?? true {
            let due = state.with { s -> Bool in
                guard !s.inFlight.contains(name) else { return false }
                if name == "lightning" && !s.lightningConfigured { return false }
                if (name == "solar" || name == "aurora") && !s.wantsOutlook { return false }
                guard now.timeIntervalSince(s.lastFetch[name] ?? .distantPast) >= cadence else { return false }
                s.inFlight.insert(name)
                return true
            }
            guard due else { continue }
            Task.detached {
                switch name {
                case "weather": let v = await ctx.weather(place); state.with { $0.weather = v }
                case "alerts": let v = await ctx.alerts(place); state.with { $0.alerts = v }
                case "lightning": let v = await ctx.lightning(place); state.with { $0.lightning = v }
                case "nowcast": let v = await ctx.nowcast(place); state.with { $0.nowcast = v }
                case "severe": let v = await ctx.severeRisk(place); state.with { $0.severe = v }
                case "tropical": let v = await ctx.tropical(); state.with { $0.tropical = v }
                case "fires": let v = await ctx.wildfires(place); state.with { $0.fires = v }
                case "air": let v = await ctx.airQuality(place); state.with { $0.air = v }
                case "hazards": let v = await ctx.hazards(place); state.with { $0.hazards = v }
                case "quakes": let v = await ctx.earthquakes(); state.with { $0.quakes = v }
                case "solar": let v = await ctx.solar(); state.with { $0.solar = v }
                case "aurora": let v = await ctx.aurora(place); state.with { $0.aurora = v }
                default: break
                }
                state.with { $0.inFlight.remove(name); $0.lastFetch[name] = Date() }
            }
        }
    }
}
