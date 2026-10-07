import Foundation
import DreadcastKit
import DreadTerminal

/// Composes the basemap, radar, rings and markers for one viewport.
struct RadarScene {
    let viewport: RadarViewport
    let palette: RadarPalette
    let minimumDBZ: Double
    let units: UnitSystem
    /// The basemap's colors and the marker's, from the theme.
    var style: MapStyle = .theme(.asteroid)
    var highlight: RGB = Theme.lamp
    static let opacity = 0.78

    /// Continuous raster coordinates (pixel centers sit at index + 0.5).
    func project(_ coordinate: GeoCoordinate) -> (x: Double, y: Double) {
        let p = viewport.pixel(for: coordinate)
        return (p.x + 0.5, p.y + 0.5)
    }

    var center: (x: Double, y: Double) { (Double(viewport.width) / 2, Double(viewport.height) / 2) }

    static func ringStep(for range: Double) -> Double {
        switch range {
        case ..<20: 5
        case ..<50: 10
        case ..<100: 25
        case ..<200: 50
        default: 100
        }
    }

    func base() -> Raster {
        var raster = Raster(width: viewport.width, height: viewport.height, fill: style.water)
        let box = viewport.boundingBox
        let margin = 1.0
        let south = box.south - margin, north = box.north + margin
        let west = box.west - margin * 2, east = box.east + margin * 2
        let map = Basemap.shared
        let fine = viewport.milesPerPixel < 1.5

        for ring in map.land where ring.intersects(south: south, north: north, west: west, east: east) {
            raster.fillPolygons([ring.points.map(project)], color: style.land)
        }
        for ring in map.lakes where ring.intersects(south: south, north: north, west: west, east: east) {
            raster.fillPolygons([ring.points.map(project)], color: style.water)
        }
        for ring in map.stateBorders where ring.intersects(south: south, north: north, west: west, east: east) {
            raster.strokePolyline(ring.points.map(project), color: style.stateBorder, alpha: fine ? 0.8 : 0.6)
        }
        for ring in map.countryBorders where ring.intersects(south: south, north: north, west: west, east: east) {
            raster.strokePolyline(ring.points.map(project), color: style.border)
        }
        for ring in map.land where ring.intersects(south: south, north: north, west: west, east: east) {
            raster.strokePolyline(ring.points.map(project), color: style.coast, alpha: 0.9, closed: true)
        }
        for ring in map.lakes where ring.intersects(south: south, north: north, west: west, east: east) {
            raster.strokePolyline(ring.points.map(project), color: style.coast, alpha: 0.6, closed: true)
        }
        let step = Self.ringStep(for: viewport.rangeMiles)
        var radius = step
        while radius <= viewport.rangeMiles + 0.01 {
            raster.strokeCircle(cx: center.x, cy: center.y, radius: radius / viewport.milesPerPixel, color: style.ring, alpha: 0.4)
            radius += step
        }
        return raster
    }

    func compose(base: Raster, field: ReflectivityField?) -> Raster {
        var raster = base
        guard let field, field.width == raster.width, field.height == raster.height else { return raster }
        for i in 0..<(field.width * field.height) {
            let value = field.dbz[i]
            guard value != ReflectivityField.none, Double(value) >= minimumDBZ else { continue }
            let color = palette.rgb(dbz: Double(value), snow: field.snow[i])
            raster.pixels[i] = Raster.mix(raster.pixels[i], color, Self.opacity)
        }
        return raster
    }

    /// Labels, rings, the location marker and lightning as half-block cell overlays.
    func overlays(placeName: String, strikes: [LightningStrike], now: Date) -> [CellOverlay] {
        var result: [CellOverlay] = []
        var occupied = Set<Int>()
        let columns = viewport.width, rows = viewport.height / 2
        func cell(_ p: (x: Double, y: Double)) -> (c: Int, r: Int) { (Int(floor(p.x)), Int(floor(p.y / 2))) }
        func place(_ text: String, column: Int, row: Int, color: RGB, bold: Bool = false) -> Bool {
            let width = TextWidth.of(text)
            guard row >= 0, row < rows, column >= 0, column + width <= columns else { return false }
            let cells = (column..<(column + width)).map { row * columns + $0 }
            guard cells.allSatisfy({ !occupied.contains($0) }) else { return false }
            cells.forEach { occupied.insert($0) }
            result.append(contentsOf: CellOverlay.text(text, column: column, row: row, color: color, bold: bold))
            return true
        }

        // Location marker and name.
        let c = cell(center)
        _ = place("✛", column: c.c, row: c.r, color: highlight, bold: true)
        let short = placeName.components(separatedBy: ",").first ?? placeName
        if !place(" " + short, column: c.c + 1, row: c.r, color: style.placeLabel, bold: true) {
            _ = place(short + " ", column: c.c - TextWidth.of(short) - 1, row: c.r, color: style.placeLabel, bold: true)
        }

        // Ring distance labels along the top of each ring.
        let step = Self.ringStep(for: viewport.rangeMiles)
        var radius = step
        while radius <= viewport.rangeMiles + 0.01 {
            let label = "\(Int(units.distance(miles: radius).rounded())) \(units.distanceUnit)"
            let y = center.y - radius / viewport.milesPerPixel
            let row = Int(floor(y / 2))
            if row >= 1 { _ = place(label, column: c.c - TextWidth.of(label) / 2, row: row, color: style.label) }
            radius += step
        }

        // Prominent cities, most important first, without collisions.
        let box = viewport.boundingBox
        var labels = 0
        let maximumLabels = max(3, columns / 12)
        for city in Basemap.shared.cities where labels < maximumLabels {
            guard city.coordinate.latitude >= box.south, city.coordinate.latitude <= box.north,
                  city.coordinate.longitude >= box.west, city.coordinate.longitude <= box.east else { continue }
            let p = cell(project(city.coordinate))
            guard abs(p.c - c.c) > 2 || abs(p.r - c.r) > 1 else { continue }
            if place("·" + city.name, column: p.c, row: p.r, color: style.label) {
                labels += 1
            } else if place(city.name + "·", column: p.c - TextWidth.of(city.name), row: p.r, color: style.label) {
                labels += 1
            }
        }

        // Lightning last so it sits on top: oldest first, newest drawn over it.
        for strike in strikes.sorted(by: { $0.timestamp < $1.timestamp }) {
            let p = cell(project(strike.coordinate))
            guard p.c >= 0, p.r >= 0, p.c < columns, p.r < rows else { continue }
            let band = strike.ageBand(at: now).rawValue
            result.append(CellOverlay(column: p.c, row: p.r, character: "•", color: Theme.lightning[band], bold: true))
        }
        return result
    }

    /// Markers drawn into the raster for image renderers.
    func drawMarkers(on raster: inout Raster, strikes: [LightningStrike], now: Date) {
        let scale = Double(raster.width) / Double(viewport.width)
        for city in Basemap.shared.cities.prefix(400) {
            let p = project(city.coordinate)
            raster.fillCircle(cx: p.x * scale, cy: p.y * scale, radius: max(1.2, scale * 0.6), color: style.label.hex, alpha: 0.8)
        }
        for strike in strikes.sorted(by: { $0.timestamp < $1.timestamp }) {
            let p = project(strike.coordinate)
            let x = p.x * scale, y = p.y * scale
            let r = max(2.5, scale * 1.1)
            raster.fillCircle(cx: x, cy: y, radius: r + 1, color: 0x000000, alpha: 0.6)
            raster.fillCircle(cx: x, cy: y, radius: r, color: Theme.lightning[strike.ageBand(at: now).rawValue].hex)
        }
        let cx = center.x * scale, cy = center.y * scale, arm = max(5, scale * 3)
        for offset in [-1.0, 0, 1] {
            raster.line(from: (cx - arm, cy + offset), to: (cx + arm, cy + offset), color: highlight.hex)
            raster.line(from: (cx + offset, cy - arm), to: (cx + offset, cy + arm), color: highlight.hex)
        }
    }
}
