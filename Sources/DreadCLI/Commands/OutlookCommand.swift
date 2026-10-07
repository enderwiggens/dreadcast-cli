import Foundation
import DreadcastKit
import DreadTerminal

/// `dread outlook`: the wider situation. Solar activity, aurora, earthquakes,
/// meteor showers and hazards near you, each from its own source.
enum OutlookCommand {
    static func run(_ ctx: Context) async throws -> ExitCode {
        let place = try await ctx.resolveLocation()
        async let solarResult = ctx.solar()
        async let quakesResult = ctx.earthquakes()
        async let auroraResult = ctx.aurora(place)
        async let hazardsResult = ctx.hazards(place)
        async let weatherResult = ctx.weather(place)
        let (solar, quakes, aurora, hazards, weather) = await (solarResult, quakesResult, auroraResult, hazardsResult, weatherResult)
        let zone = weather.value?.timeZone ?? ctx.timeZone(for: place)
        let fmt = Formatter(units: ctx.units, timeZone: zone)
        let showers = Array(MeteorCalendar.upcoming(at: ctx.now, timeZone: zone).prefix(2))

        switch ctx.mode {
        case .json:
            ctx.writeJSON(OutlookJSON(place: place, solar: solar.value, quakes: quakes.value, aurora: aurora.value,
                                      hazards: hazards.value, showers: showers, zone: zone, now: ctx.now))
        case .plain:
            ctx.write(plain(place: place, solar: solar, quakes: quakes, aurora: aurora, hazards: hazards, showers: showers, fmt: fmt, ctx: ctx))
        case .pretty:
            ctx.write(pretty(place: place, solar: solar, quakes: quakes, aurora: aurora, hazards: hazards,
                             weather: weather.value, showers: showers, fmt: fmt, ctx: ctx))
        }
        let failures = [solar.value == nil, quakes.value == nil, aurora.value == nil, hazards.value == nil].filter { $0 }.count
        return failures == 4 ? .unavailable : .ok
    }

    static func section(_ title: String, _ subtitle: String, source: String, ctx: Context, width: Int) -> String {
        let s = ctx.styler
        return TextWidth.spread("  " + s.bold(title) + (subtitle.isEmpty ? "" : s.paint("  " + subtitle, Theme.mist)),
                                s.paint(source, Theme.faint), width: width)
    }

    static func pretty(place: Place, solar: Fetched<SolarOutlook>, quakes: Fetched<EarthquakeSnapshot>,
                       aurora: Fetched<AuroraReading>, hazards: Fetched<HazardSummary>, weather: WeatherReport?,
                       showers: [MeteorCalendar.Shower], fmt: Formatter, ctx: Context, width requested: Int? = nil) -> [String] {
        let s = ctx.styler
        let width = requested ?? min(max(ctx.terminal.columns - 2, 64), 96)
        var lines = [""]
        lines.append(TextWidth.spread(ctx.title("OUTLOOK", place: place),
                                      s.paint(fmt.day(ctx.now), Theme.faint), width: width))
        lines.append("")

        // Solar activity: Kp in 3-hour blocks, observed then predicted.
        lines.append(section("SOLAR ACTIVITY", "", source: "NOAA SWPC · Kp, 3-hour blocks", ctx: ctx, width: width))
        if let outlook = solar.value {
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let start = utc.startOfDay(for: ctx.now)
            let samples = outlook.samples.filter { $0.time >= start && $0.time < start.addingTimeInterval(3 * 86400) }
            let labels = ["Kp 9 ", "   6 ", "   3 "]
            for row in stride(from: 2, through: 0, by: -1) {
                var line = "  " + s.paint(labels[2 - row], Theme.mist) + s.paint("│", Theme.faint)
                for sample in samples {
                    let character = Charts.block(sample.kp / 9, row: row, of: 3)
                    let color: RGB = sample.kp >= 5 ? Theme.advisory : sample.kind == .predicted ? Theme.violet : Theme.mint
                    line += character == " " ? "  " : s.paint(String(repeating: String(character), count: 2), color)
                }
                lines.append(line)
            }
            lines.append("  " + String(repeating: " ", count: 5) + s.paint("└" + String(repeating: "─", count: samples.count * 2), Theme.faint))
            let dayFormatter = DateFormatter()
            dayFormatter.locale = Locale(identifier: "en_US_POSIX")
            dayFormatter.timeZone = TimeZone(identifier: "UTC")
            dayFormatter.dateFormat = "EEE"
            let dayLabels = (0..<3).map { TextWidth.pad(dayFormatter.string(from: start.addingTimeInterval(Double($0) * 86400)), to: 16) }.joined()
            lines.append("  " + String(repeating: " ", count: 6) + s.paint(dayLabels, Theme.mist) + s.paint("UTC  ", Theme.faint)
                         + s.paint("██", Theme.mint) + s.paint(" observed  ", Theme.faint) + s.paint("██", Theme.violet)
                         + s.paint(" predicted  ", Theme.faint) + s.paint("██", Theme.advisory) + s.paint(" G1+", Theme.faint))
            if let observed = outlook.latestObserved(at: ctx.now) {
                var text = "  Now " + s.bold("Kp \(String(format: "%.0f", observed.kp))") + " (observed)."
                if let peak = outlook.peak(after: ctx.now), peak.kp > observed.kp {
                    let scale = SolarOutlook.geomagneticScale(kp: peak.kp)
                    text += " Highest " + s.paint("Kp \(String(format: "%.0f", peak.kp)) \(fmt.weekday(peak.time)) \(fmt.time(peak.time))", scale == nil ? Theme.porcelain : Theme.advisory)
                    text += scale.map { ": \($0) storm possible." } ?? "."
                }
                lines.append(text)
            }
        } else {
            lines.append("  " + s.paint("Unavailable: \(solar.error ?? "unknown error").", Theme.advisory))
        }
        if let reading = aurora.value {
            let text: String
            if reading.probability >= 10 {
                text = "Aurora: \(Int(reading.probability))% chance overhead in the latest OVATION forecast."
            } else if reading.poleward >= 20 {
                text = "Aurora: unlikely overhead; up to \(Int(reading.poleward))% toward the pole on a clear horizon."
            } else {
                text = "Aurora: not expected at \(String(format: "%.0f", abs(place.coordinate.latitude)))°\(place.coordinate.latitude >= 0 ? "N" : "S")."
            }
            lines.append("  " + s.paint(text, Theme.mist))
        }
        lines.append("")

        // Earthquakes.
        lines.append(section("EARTHQUAKES", "M2.5+, past 24 h", source: "USGS", ctx: ctx, width: width))
        if let snapshot = quakes.value {
            let strongest = snapshot.events.sorted { $0.magnitude > $1.magnitude }.prefix(4)
            let nearest = snapshot.events.min { $0.coordinate.distanceMiles(to: place.coordinate) < $1.coordinate.distanceMiles(to: place.coordinate) }
            var shown = Array(strongest)
            if let nearest, !shown.contains(where: { $0.id == nearest.id }) { shown.append(nearest) }
            if shown.isEmpty { lines.append("  " + s.paint("None reported.", Theme.mist)) }
            for quake in shown {
                let magnitude = s.paint(TextWidth.pad(String(format: "M%.1f", quake.magnitude), to: 7), quake.magnitude >= 6 ? Theme.warning : quake.magnitude >= 5 ? Theme.advisory : Theme.porcelain, bold: true)
                var line = "  " + magnitude + TextWidth.pad(TextWidth.truncate(quake.place, to: 38), to: 40)
                    + s.paint(TextWidth.pad(String(format: "%.0f km deep", quake.depthKM), to: 13), Theme.mist)
                    + s.paint(TextWidth.pad(Formatter.ago(quake.time, now: ctx.now), to: 10, align: .right), Theme.mist)
                if quake.id == nearest?.id {
                    line += s.paint("  nearest, \(fmt.distance(miles: quake.coordinate.distanceMiles(to: place.coordinate))) \(Compass.point(place.coordinate.bearingDegrees(to: quake.coordinate)))", Theme.faint)
                }
                lines.append(line)
            }
        } else {
            lines.append("  " + s.paint("Unavailable: \(quakes.error ?? "unknown error").", Theme.advisory))
        }
        lines.append("")

        // Meteor showers with the moon and forecast cloud cover on the peak night.
        lines.append(section("METEOR SHOWERS", "", source: "American Meteor Society · Open-Meteo clouds", ctx: ctx, width: width))
        if showers.isEmpty {
            lines.append("  " + s.paint("This edition of the AMS calendar has ended. Update dread for new dates.", Theme.advisory))
        }
        for shower in showers {
            let peak = shower.peakDate(in: fmt.timeZone)
            let moon = LunarPhase(at: peak)
            let clouds = weather.flatMap { report -> Double? in
                let night = report.hourly.filter { $0.time >= peak.addingTimeInterval(-3600) && $0.time <= peak.addingTimeInterval(5 * 3600) }
                let values = night.compactMap(\.cloudCover)
                return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            }
            var verdict: (String, RGB)
            if moon.illumination > 0.6 { verdict = ("bright moon", Theme.advisory) }
            else if let clouds, clouds > 60 { verdict = ("cloudy", Theme.advisory) }
            else if clouds == nil { verdict = ("clouds not yet forecast", Theme.faint) }
            else { verdict = ("good", Theme.mint) }
            if moon.illumination <= 0.6, let clouds, clouds <= 30 { verdict = ("good", Theme.mint) }
            lines.append("  " + TextWidth.pad(shower.name, to: 18) + TextWidth.pad("peak \(shower.peakLabel)", to: 20)
                         + TextWidth.pad("~\(shower.rate)/hr", to: 9)
                         + s.paint(TextWidth.pad("moon \(Int((moon.illumination * 100).rounded()))%", to: 10), Theme.mist)
                         + s.paint(TextWidth.pad(clouds.map { "clouds \(Int($0))%" } ?? "", to: 12), Theme.mist)
                         + s.paint(verdict.0, verdict.1))
        }
        lines.append("")

        // Hazards near the location.
        lines.append(section("NEARBY HAZARDS", "", source: "NTWC/PTWC · USGS · NOAA HMS · SWPC · CAMS", ctx: ctx, width: width))
        if let summary = hazards.value {
            let label = { (text: String) in "  " + s.paint(TextWidth.pad(text, to: 10), Theme.mist) }
            if let tsunamis = summary.tsunamis {
                if tsunamis.isEmpty {
                    lines.append(label("Tsunami") + "no active warnings, watches or advisories in the latest bulletins")
                } else {
                    for item in tsunamis.prefix(2) {
                        lines.append(label("Tsunami") + s.paint(item.title, item.level == "warning" ? Theme.warning : Theme.advisory)
                                     + (item.detail.map { s.paint(" · " + $0, Theme.mist) } ?? ""))
                    }
                }
            } else if let failure = summary.failures[HazardKind.tsunamis.rawValue] {
                lines.append(label("Tsunami") + s.paint("unavailable: \(failure)", Theme.advisory))
            }
            if let volcanoes = summary.elevatedVolcanoes {
                if let nearest = volcanoes.first {
                    let distance = nearest.distanceMiles.map { ", \(fmt.distance(miles: $0)) away" } ?? ""
                    lines.append(label("Volcano") + "\(nearest.title) at " + s.paint(nearest.detail ?? nearest.level.capitalized, Theme.advisory) + distance
                                 + (volcanoes.count > 1 ? s.paint("  +\(volcanoes.count - 1) more elevated", Theme.faint) : ""))
                } else {
                    lines.append(label("Volcano") + "no US volcanoes above normal")
                }
            }
            if let smoke = summary.smokeAtLocation {
                let nearby = summary.smokeNearbyCount ?? 0
                let text = smoke == "none" ? (nearby > 0 ? "none overhead; \(nearby) area\(nearby == 1 ? "" : "s") within \(fmt.distance(miles: 100))" : "none analyzed nearby")
                    : "\(smoke) smoke analyzed overhead"
                lines.append(label("Smoke") + text + s.paint("  (satellite, not surface air quality)", Theme.faint))
            }
            if let mhz = summary.radioMHz {
                lines.append(label("HF radio") + (mhz < 1 ? "no significant absorption" : String(format: "absorption up to %.0f MHz", mhz))
                             + s.paint("  (modeled; not cellular service)", Theme.faint))
            }
            if let dust = summary.dust {
                lines.append(label("Dust") + String(format: "%.0f µg/m³", dust) + (dust > 100 ? s.paint("  elevated", Theme.advisory) : s.paint("  low", Theme.faint)))
            }
        } else {
            lines.append("  " + s.paint("Unavailable: \(hazards.error ?? "unknown error").", Theme.advisory))
        }
        lines.append("")
        if ctx.quipsEnabled {
            let kp = solar.value?.latestObserved(at: ctx.now)?.kp
            lines.append("  " + s.paint("OUTLOOK COMMENTARY", Theme.faint) + "  " + s.paint(Quip.outlook(kp: kp), Theme.violet, italic: true))
            lines.append("")
        }
        return lines
    }

    static func plain(place: Place, solar: Fetched<SolarOutlook>, quakes: Fetched<EarthquakeSnapshot>,
                      aurora: Fetched<AuroraReading>, hazards: Fetched<HazardSummary>,
                      showers: [MeteorCalendar.Shower], fmt: Formatter, ctx: Context) -> [String] {
        var lines = ["Outlook for \(place.name)."]
        if let observed = solar.value?.latestObserved(at: ctx.now) {
            lines.append("Solar activity: Kp \(String(format: "%.0f", observed.kp)) observed (NOAA SWPC).")
        }
        if let reading = aurora.value { lines.append("Aurora probability overhead: \(Int(reading.probability))%.") }
        if let events = quakes.value?.events.sorted(by: { $0.magnitude > $1.magnitude }).prefix(3) {
            for quake in events { lines.append(String(format: "Earthquake M%.1f, ", quake.magnitude) + "\(quake.place), \(Formatter.ago(quake.time, now: ctx.now)).") }
        }
        for shower in showers { lines.append("\(shower.name): peak \(shower.peakLabel), about \(shower.rate) per hour.") }
        if let summary = hazards.value {
            if let smoke = summary.smokeAtLocation { lines.append("Smoke overhead: \(smoke).") }
            if let dust = summary.dust { lines.append(String(format: "Dust: %.0f µg/m³.", dust)) }
        }
        return lines
    }
}

struct OutlookJSON: Encodable {
    struct Kp: Encodable { let time: Date; let kp: Double; let kind: String; let scale: String? }
    struct Quake: Encodable { let id: String; let magnitude: Double; let place: String; let time: Date; let latitude: Double; let longitude: Double; let depthKM: Double; let distanceMiles: Double }
    struct Shower: Encodable { let name: String; let peak: String; let rate: Int; let moonIllumination: Double }
    let schema = "dreadcast.outlook/1"
    let location: LocationJSON
    let kp: [Kp]?
    let auroraProbability: Double?
    let earthquakes: [Quake]?
    let meteorShowers: [Shower]
    let hazards: HazardSummary?

    init(place: Place, solar: SolarOutlook?, quakes: EarthquakeSnapshot?, aurora: AuroraReading?,
         hazards: HazardSummary?, showers: [MeteorCalendar.Shower], zone: TimeZone, now: Date) {
        location = LocationJSON(place)
        kp = solar?.samples.filter { $0.time >= now.addingTimeInterval(-86400) }.map { Kp(time: $0.time, kp: $0.kp, kind: $0.kind.rawValue, scale: $0.stormScale) }
        auroraProbability = aurora?.probability
        earthquakes = quakes?.events.map {
            Quake(id: $0.id, magnitude: $0.magnitude, place: $0.place, time: $0.time, latitude: $0.coordinate.latitude,
                  longitude: $0.coordinate.longitude, depthKM: $0.depthKM, distanceMiles: ($0.coordinate.distanceMiles(to: place.coordinate)).rounded())
        }
        meteorShowers = showers.map { Shower(name: $0.name, peak: $0.peakLabel, rate: $0.rate, moonIllumination: (LunarPhase(at: $0.peakDate(in: zone)).illumination * 100).rounded() / 100) }
        self.hazards = hazards
    }
}
