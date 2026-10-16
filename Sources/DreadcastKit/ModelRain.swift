import Foundation

/// Rain timing from the forecast model's 15-minute precipitation, for places no radar
/// reaches. A step's total covers the 15 minutes before its time, so each step starts
/// 15 minutes before it's stamped. It has the model's resolution: no motion, cells or
/// reflectivity, and showers that form sooner or later than modeled aren't foreseen.
public struct ModelRain: Sendable {
    public struct Step: Sendable {
        public let start: Date
        /// The step's total, in the report's precipitation unit.
        public let precipitation: Double?
    }

    public static let stepMinutes = 15
    /// Two hours, as far as radar timing looks.
    public static let horizonMinutes = 120

    public let now: Date
    public let units: UnitSystem
    /// From the step under way, for two hours.
    public let steps: [Step]
    /// Where the steps end: two hours from now, or sooner for an old reading.
    public let until: Date
    public let rainingNow: Bool
    /// When the first wet step starts; nil when it's raining now or no step is wet.
    public let arrival: Date?
    /// When the rain stops, if it does within two hours.
    public let end: Date?
    /// Minutes of rain at radar's heavy rate or more.
    public let heavyMinutes: Int

    /// Rain in a 15-minute step: 0.1 mm, or 0.004 in.
    public static func rainThreshold(_ units: UnitSystem) -> Double { units == .imperial ? 0.004 : 0.1 }

    /// Heavy rain in a 15-minute step: the rate radar calls heavy, for 15 minutes.
    public static func heavyThreshold(_ units: UnitSystem) -> Double {
        let millimeters = RainRate.millimetersPerHour(dbz: Nowcaster.heavyThreshold) * Double(stepMinutes) / 60
        return units == .imperial ? millimeters / 25.4 : millimeters
    }

    /// Nil when the report has no step under way, as with an old reading or one without
    /// 15-minute data.
    public init?(report: WeatherReport, now: Date) {
        let length = TimeInterval(Self.stepMinutes * 60)
        let horizon = now.addingTimeInterval(TimeInterval(Self.horizonMinutes * 60))
        let steps = report.minutely
            .filter { $0.time > now && $0.time.addingTimeInterval(-length) < horizon }
            .map { Step(start: $0.time.addingTimeInterval(-length), precipitation: $0.precipitation) }
        guard let first = steps.first, first.start <= now else { return nil }

        let rain = Self.rainThreshold(report.units), heavy = Self.heavyThreshold(report.units)
        let wet = steps.map { ($0.precipitation ?? 0) >= rain }
        self.now = now
        self.units = report.units
        self.steps = steps
        until = min(horizon, steps[steps.count - 1].start.addingTimeInterval(length))
        rainingNow = wet[0]
        let firstWet = wet.firstIndex(of: true)
        arrival = rainingNow ? nil : firstWet.map { steps[$0].start }
        end = firstWet.flatMap { start in wet[start...].firstIndex(of: false).map { steps[$0].start } }
        heavyMinutes = steps.indices.filter { (steps[$0].precipitation ?? 0) >= heavy }.reduce(0) { total, i in
            let start = max(steps[i].start, now)
            let stop = min(steps[i].start.addingTimeInterval(length), horizon)
            return total + max(0, Int((stop.timeIntervalSince(start) / 60).rounded()))
        }
    }

    /// Whole minutes from now to `date`, never negative.
    public func minutes(until date: Date) -> Int { max(0, Int((date.timeIntervalSince(now) / 60).rounded())) }

    public var arrivalMinutes: Int? { arrival.map(minutes(until:)) }
    public var endMinutes: Int? { end.map(minutes(until:)) }
    /// The steps reach two hours ahead.
    public var coversTwoHours: Bool { minutes(until: until) >= Self.horizonMinutes }

    /// The total of the step under way `minute` minutes from now; nil past the steps.
    public func precipitation(atMinute minute: Int) -> Double? {
        let time = now.addingTimeInterval(TimeInterval(minute * 60))
        return steps.last { $0.start <= time }.flatMap { step in
            time < step.start.addingTimeInterval(TimeInterval(Self.stepMinutes * 60)) ? (step.precipitation ?? 0) : nil
        }
    }

    /// The radar reflectivity that would give the step's rain rate, to draw the model on
    /// radar's scale; 0 when dry.
    public func equivalentDBZ(atMinute minute: Int) -> Double? {
        precipitation(atMinute: minute).map { total in
            let millimeters = units == .imperial ? total * 25.4 : total
            return RainRate.dbz(millimetersPerHour: millimeters * 60 / Double(Self.stepMinutes))
        }
    }
}
