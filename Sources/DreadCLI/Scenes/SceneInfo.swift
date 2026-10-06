import Foundation
import DreadcastKit
import DreadTerminal

/// The readings under a scene, as ordinary terminal text: the terminal window is the
/// card. The temperature is set in pixel type. The scene's line appears only when no
/// alert is active and alert data is known.
enum SceneInfo {
    static let rows = 4

    static func lines(scene: SceneID, period: ScenePeriod, readings: SceneCommand.Readings, ctx: Context, width: Int) -> [String] {
        let s = ctx.styler
        let report = readings.weather?.value
        let zone = report?.timeZone ?? readings.place.map(ctx.timeZone(for:)) ?? .current
        let fmt = Formatter(units: ctx.units, timeZone: zone)

        var big = [String](repeating: "", count: rows)
        var bigWidth = 0
        if let temperature = report?.current.temperature {
            let text = "\(Int(temperature.rounded()))°" + (ctx.units == .imperial ? "F" : "C")
            big = PixelFont.lines(text, styler: s, color: Theme.porcelain, accent: scene.accent)
            bigWidth = PixelFont.width(text)
        }

        let title = s.paint(scene.title, scene.accent, bold: true) + s.paint(" · \(period.title)", Theme.mist)
        var left: [String] = []
        if let place = readings.place, let report {
            let c = report.current
            left.append(s.bold(WeatherCondition.description(c.weatherCode)) + s.paint(" · " + place.name, Theme.porcelain))
            left.append(s.paint("Feels \(fmt.temperature(c.apparentTemperature)) · Humidity \(fmt.percent(c.humidity)) · Wind \(fmt.wind(speed: c.windSpeed, gust: c.windGusts, direction: c.windDirection))", Theme.mist))
        } else if readings.place == nil {
            left.append(s.paint("Run dread setup for live conditions.", Theme.mist))
        } else {
            left.append(s.paint("Conditions unavailable: \(readings.weather?.error ?? "unknown error")", Theme.advisory))
        }

        // Alerts come before any line, and replace it.
        let alertList = readings.alerts?.value ?? []
        let alertsUnknown = readings.place?.isUnitedStates == true && readings.alerts?.value == nil
        if let first = alertList.first {
            let color = NowCommand.alertColor(first)
            var status = s.isEnabled ? s.paint(" ▲ \(first.event.uppercased()) ", TextStyle(foreground: Theme.midnight, background: color, bold: true)) : "▲ \(first.event.uppercased())"
            if let end = first.endsOrExpires { status += s.paint("  until \(fmt.until(end, now: ctx.now)) \(fmt.zoneAbbreviation(end))", color) }
            if alertList.count > 1 { status += s.paint("  +\(alertList.count - 1) more · dread alerts", Theme.faint) }
            left.append(status)
        } else if alertsUnknown {
            left.append(s.paint("Alerts unavailable. This is not an all-clear.", Theme.advisory))
        } else if readings.place?.isUnitedStates == true {
            left.append(s.paint("No active alerts", Theme.mint))
        }
        if alertList.isEmpty, !alertsUnknown, ctx.quipsEnabled {
            left.append(s.paint(scene.line(for: period), scene.accent, italic: true))
        }

        // Every reading keeps its source and age.
        var sources: [String] = []
        if readings.place != nil { sources.append("OPEN-METEO") }
        if readings.place?.isUnitedStates == true { sources.append("NWS") }
        if let stored = readings.weather?.storedAt {
            sources.append((readings.weather?.isStale == true ? "stale · " : "") + "updated " + Formatter.ago(stored, now: ctx.now))
        }
        let attribution = sources.isEmpty ? "" : s.paint(sources.joined(separator: " · "), readings.weather?.isStale == true ? Theme.advisory : Theme.faint)

        let gutter = bigWidth > 0 ? 3 : 0
        let available = max(10, width - 2 - bigWidth - gutter)
        while left.count < rows { left.append("") }
        var right = [String](repeating: "", count: left.count)
        // The scene title and the attribution each take the first row with room.
        for item in [title, attribution] where !item.isEmpty {
            if let row = left.indices.first(where: { right[$0].isEmpty && TextWidth.of(left[$0]) + TextWidth.of(item) + 2 <= available }) {
                right[row] = item
            } else {
                left.append("")
                right.append(item)
            }
        }
        var result: [String] = []
        for i in left.indices {
            let art = i < big.count ? big[i] : ""
            let body = right[i].isEmpty ? left[i] : TextWidth.spread(left[i], right[i], width: available)
            result.append("  " + TextWidth.pad(art, to: bigWidth) + String(repeating: " ", count: gutter) + body)
        }
        return result
    }
}

/// A 5×7 pixel font for the temperature, drawn with half blocks: four rows of text.
enum PixelFont {
    static let glyphs: [Character: [String]] = [
        "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "3": ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
        "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
        "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
        "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
        "-": [".....", ".....", ".....", "####.", ".....", ".....", "....."],
        "°": [".#.", "#.#", ".#.", "...", "...", "...", "..."],
        "F": ["####", "#...", "#...", "###.", "#...", "#...", "#..."],
        "C": [".###", "#...", "#...", "#...", "#...", "#...", ".###"]
    ]

    static func width(_ text: String) -> Int {
        let widths = text.compactMap { glyphs[$0]?.first?.count }
        return widths.reduce(0, +) + max(0, widths.count - 1)
    }

    /// Four lines of half-block characters: each line holds two rows of pixels.
    /// Digits use `color`; the degree sign and unit use `accent`.
    static func lines(_ text: String, styler: Styler, color: RGB, accent: RGB) -> [String] {
        var columns: [(top: [Bool], tone: RGB)] = []
        for (index, character) in text.enumerated() {
            guard let rows = glyphs[character] else { continue }
            if index > 0 { columns.append(([Bool](repeating: false, count: 8), color)) }
            let tone = character.isNumber || character == "-" ? color : accent
            for x in 0..<(rows.first?.count ?? 0) {
                var pixels = rows.map { row in Array(row)[x] == "#" }
                pixels.append(false)
                columns.append((pixels, tone))
            }
        }
        return (0..<4).map { row in
            var line = ""
            var run = ""
            var runTone: RGB?
            func flush() {
                guard !run.isEmpty else { return }
                line += runTone.map { styler.paint(run, $0, bold: false) } ?? run
                run = ""
            }
            for column in columns {
                let top = column.top[row * 2], bottom = column.top[row * 2 + 1]
                let character = top && bottom ? "█" : top ? "▀" : bottom ? "▄" : " "
                let tone: RGB? = character == " " ? nil : column.tone
                if tone != runTone { flush(); runTone = tone }
                run += character
            }
            flush()
            return line
        }
    }
}
