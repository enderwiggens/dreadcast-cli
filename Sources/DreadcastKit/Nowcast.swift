import Foundation

/// A short-range rain forecast for one location, extrapolated from radar motion.
///
/// Method: estimate echo motion between recent frames with normalized cross-correlation,
/// then trace backward from the location along that motion through the latest frame.
/// It is timing guidance, not a rainfall total, and it cannot foresee storms that
/// develop or dissipate along the way.
public struct Nowcast: Codable, Sendable {
    public enum Confidence: String, Codable, Sendable { case high, medium, low }
    public enum Trend: String, Codable, Sendable { case intensifying, steady, weakening }

    public struct Step: Codable, Sendable {
        public let minutes: Int
        /// Predicted reflectivity near the location; nil once the trace leaves radar coverage.
        public let dbz: Double?
    }

    public let generatedAt: Date
    public let frameTimes: [Date]
    /// Whose radar the nowcast came from, such as NOAA MRMS or RainViewer.
    public var source: String?
    public let steps: [Step]
    /// Direction echoes are moving toward, degrees clockwise from north.
    public let motionBearing: Double?
    public let motionMPH: Double?
    public let currentDBZ: Double?
    public let arrivalMinutes: Int?
    public let endMinutes: Int?
    public let heavyStartMinutes: Int?
    public let heavyMinutes: Int
    public let peakDBZ: Double?
    public let peakMinutes: Int?
    public let confidence: Confidence
    public let trend: Trend
    public let nearestEchoMiles: Double?
    public let nearestEchoBearing: Double?
    public let cells: [StormCell]

    public var latestFrame: Date? { frameTimes.last }
    public var isRainingNow: Bool { (currentDBZ ?? -99) >= Nowcaster.rainThreshold }
}

public struct StormCell: Codable, Sendable {
    public let id: Int
    public let latitude: Double
    public let longitude: Double
    public let distanceMiles: Double
    public let bearing: Double
    public let maxDBZ: Double
    public let areaSquareMiles: Double
    /// Nearest the cell's center is expected to pass, if it keeps moving with the echoes.
    public let closestApproachMiles: Double?
    public let closestApproachMinutes: Int?
    public let arrivalMinutes: Int?

    public var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }
}

public enum Nowcaster {
    public static let rainThreshold = 20.0
    public static let heavyThreshold = 40.0
    public static let horizonMinutes = 120
    public static let stepMinutes = 2

    /// Builds a nowcast from frames covering a viewport centered on the location.
    /// - Parameter fields: radar fields, oldest first, all sampled on `viewport`.
    public static func forecast(fields: [ReflectivityField], viewport: RadarViewport, now: Date = Date()) -> Nowcast {
        let ordered = fields.sorted { $0.time < $1.time }
        let center = (x: Double(viewport.width) / 2 - 0.5, y: Double(viewport.height) / 2 - 0.5)
        let mpp = viewport.milesPerPixel
        guard let latest = ordered.last else {
            return empty(now: now, frames: [], confidence: .low)
        }

        // Motion from up to the last three frame pairs.
        let recent = Array(ordered.suffix(4))
        var vectors: [(vx: Double, vy: Double, score: Double)] = []
        for (a, b) in zip(recent, recent.dropFirst()) {
            let minutes = b.time.timeIntervalSince(a.time) / 60
            guard minutes >= 2, minutes <= 30,
                  let shift = estimateShift(from: a, to: b, maximumMiles: 15 * minutes / 10 * 1.4, milesPerPixel: mpp) else { continue }
            vectors.append((shift.dx / minutes, shift.dy / minutes, shift.score))
        }

        let weight = vectors.reduce(0) { $0 + $1.score }
        var vx = 0.0, vy = 0.0, score = 0.0, consistency = 0.0
        if weight > 0 {
            vx = vectors.reduce(0) { $0 + $1.vx * $1.score } / weight
            vy = vectors.reduce(0) { $0 + $1.vy * $1.score } / weight
            score = weight / Double(vectors.count)
            let speed = hypot(vx, vy)
            let spread = vectors.map { hypot($0.vx - vx, $0.vy - vy) }.reduce(0, +) / Double(vectors.count)
            consistency = speed > 0.01 ? max(0, 1 - spread / max(speed, 0.05)) : (vectors.count > 1 ? 0.5 : 0)
        }

        // Trace backward along the motion through the latest frame.
        let radius = max(1, Int((1.5 / mpp).rounded()))
        var steps: [Nowcast.Step] = []
        for minutes in stride(from: 0, through: horizonMinutes, by: stepMinutes) {
            let x = center.x - vx * Double(minutes)
            let y = center.y - vy * Double(minutes)
            if x < -0.5 || y < -0.5 || x > Double(viewport.width) - 0.5 || y > Double(viewport.height) - 0.5 {
                steps.append(.init(minutes: minutes, dbz: nil))
                continue
            }
            let value = latest.maximum(nearX: x, y: y, radius: radius).map(Double.init) ?? -32
            steps.append(.init(minutes: minutes, dbz: value))
        }

        let current = steps.first?.dbz.flatMap { $0 > -32 ? $0 : nil }
        let raining = (current ?? -99) >= rainThreshold
        var arrival: Int?
        var end: Int?
        var heavyStart: Int?
        var heavyMinutes = 0
        var peak: (dbz: Double, minutes: Int)?
        for step in steps {
            guard let dbz = step.dbz else { continue }
            if dbz >= rainThreshold {
                if !raining, arrival == nil { arrival = step.minutes }
                if peak == nil || dbz > peak!.dbz { peak = (dbz, step.minutes) }
            } else if (raining || arrival != nil), end == nil {
                end = step.minutes
            }
            if dbz >= heavyThreshold {
                if heavyStart == nil { heavyStart = step.minutes }
                if end == nil { heavyMinutes += stepMinutes }
            }
        }

        // Echo trend across the frames used for motion.
        func mass(_ field: ReflectivityField) -> Double {
            field.dbz.reduce(0) { $0 + max(0, Double($1 == ReflectivityField.none ? 0 : $1) - 20) }
        }
        let earliestMass = recent.first.map(mass) ?? 0
        let latestMass = mass(latest)
        let trend: Nowcast.Trend
        if earliestMass < 50 && latestMass < 50 { trend = .steady }
        else if latestMass > earliestMass * 1.25 { trend = .intensifying }
        else if latestMass < earliestMass * 0.8 { trend = .weakening }
        else { trend = .steady }

        var level = vectors.isEmpty ? 0 : (score >= 0.75 ? 2 : score >= 0.5 ? 1 : 0)
        if consistency < 0.65 { level -= 1 }
        if let arrival, arrival > 60 { level -= 1 }
        if trend != .steady { level = min(level, 1) }
        if !raining, arrival == nil, !vectors.isEmpty { level = max(level, 1) }
        let confidence: Nowcast.Confidence = level >= 2 ? .high : level == 1 ? .medium : .low

        // Motion in miles: +x is east, +y is south.
        let mphEast = vx * mpp * 60, mphSouth = vy * mpp * 60
        let speed = hypot(mphEast, mphSouth)
        let bearing = speed >= 3 ? (atan2(mphEast, -mphSouth) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360) : nil

        let nearest = nearestEcho(in: latest, center: center, milesPerPixel: mpp)
        let cells = detectCells(in: latest, viewport: viewport, velocity: (vx * mpp, -vy * mpp))

        return Nowcast(generatedAt: now, frameTimes: ordered.map(\.time), steps: steps,
                       motionBearing: vectors.isEmpty ? nil : bearing, motionMPH: vectors.isEmpty ? nil : speed,
                       currentDBZ: current, arrivalMinutes: arrival, endMinutes: end,
                       heavyStartMinutes: heavyStart, heavyMinutes: heavyMinutes,
                       peakDBZ: peak?.dbz, peakMinutes: peak?.minutes, confidence: confidence, trend: trend,
                       nearestEchoMiles: nearest?.miles, nearestEchoBearing: nearest?.bearing, cells: cells)
    }

    static func empty(now: Date, frames: [Date], confidence: Nowcast.Confidence) -> Nowcast {
        Nowcast(generatedAt: now, frameTimes: frames, steps: [], motionBearing: nil, motionMPH: nil,
                currentDBZ: nil, arrivalMinutes: nil, endMinutes: nil, heavyStartMinutes: nil, heavyMinutes: 0,
                peakDBZ: nil, peakMinutes: nil, confidence: confidence, trend: .steady,
                nearestEchoMiles: nil, nearestEchoBearing: nil, cells: [])
    }

    /// Best echo displacement from `a` to `b` in full-resolution pixels, by normalized
    /// cross-correlation on a downsampled intensity grid.
    static func estimateShift(from a: ReflectivityField, to b: ReflectivityField,
                              maximumMiles: Double, milesPerPixel: Double) -> (dx: Double, dy: Double, score: Double)? {
        guard a.width == b.width, a.height == b.height else { return nil }
        let factor = max(1, Int(ceil(Double(max(a.width, a.height)) / 140)))
        let w = a.width / factor, h = a.height / factor
        guard w >= 8, h >= 8 else { return nil }

        func grid(_ field: ReflectivityField) -> [Float] {
            var out = [Float](repeating: 0, count: w * h)
            for gy in 0..<h {
                for gx in 0..<w {
                    var best: Int8 = .min
                    for dy in 0..<factor {
                        for dx in 0..<factor {
                            let v = field.dbz[(gy * factor + dy) * field.width + gx * factor + dx]
                            if v > best { best = v }
                        }
                    }
                    out[gy * w + gx] = best == .min ? 0 : max(0, Float(best) - 15)
                }
            }
            return out
        }

        let ga = grid(a), gb = grid(b)
        let echoA = ga.reduce(0, +), echoB = gb.reduce(0, +)
        guard echoA > 40, echoB > 40 else { return nil }

        let maxShift = max(2, min(w / 3, Int(ceil(maximumMiles / (milesPerPixel * Double(factor))))))
        var scores = [Float](repeating: -1, count: (2 * maxShift + 1) * (2 * maxShift + 1))
        var best: (dx: Int, dy: Int, score: Float) = (0, 0, -1)
        ga.withUnsafeBufferPointer { pa in
            gb.withUnsafeBufferPointer { pb in
                for sy in -maxShift...maxShift {
                    for sx in -maxShift...maxShift {
                        var dot: Float = 0, aa: Float = 0, bb: Float = 0
                        let y0 = max(0, -sy), y1 = min(h, h - sy)
                        let x0 = max(0, -sx), x1 = min(w, w - sx)
                        guard y1 > y0, x1 > x0 else { continue }
                        for y in y0..<y1 {
                            let rowA = y * w, rowB = (y + sy) * w + sx
                            for x in x0..<x1 {
                                let va = pa[rowA + x], vb = pb[rowB + x]
                                dot += va * vb; aa += va * va; bb += vb * vb
                            }
                        }
                        let score = aa > 0 && bb > 0 ? dot / (aa * bb).squareRoot() : -1
                        scores[(sy + maxShift) * (2 * maxShift + 1) + sx + maxShift] = score
                        if score > best.score { best = (sx, sy, score) }
                    }
                }
            }
        }
        guard best.score > 0.2 else { return nil }

        // Parabolic sub-pixel refinement along each axis.
        func value(_ sx: Int, _ sy: Int) -> Float? {
            guard abs(sx) <= maxShift, abs(sy) <= maxShift else { return nil }
            let v = scores[(sy + maxShift) * (2 * maxShift + 1) + sx + maxShift]
            return v > -1 ? v : nil
        }
        func refine(_ left: Float?, _ middle: Float, _ right: Float?) -> Double {
            guard let left, let right else { return 0 }
            let denominator = left - 2 * middle + right
            guard abs(denominator) > 1e-6 else { return 0 }
            return Double(max(-0.5, min(0.5, 0.5 * (left - right) / denominator)))
        }
        let fx = Double(best.dx) + refine(value(best.dx - 1, best.dy), best.score, value(best.dx + 1, best.dy))
        let fy = Double(best.dy) + refine(value(best.dx, best.dy - 1), best.score, value(best.dx, best.dy + 1))
        return (fx * Double(factor), fy * Double(factor), Double(best.score))
    }

    static func nearestEcho(in field: ReflectivityField, center: (x: Double, y: Double), milesPerPixel: Double) -> (miles: Double, bearing: Double)? {
        var best: (d2: Double, dx: Double, dy: Double)?
        for y in 0..<field.height {
            for x in 0..<field.width {
                let v = field.dbz[y * field.width + x]
                guard v != ReflectivityField.none, Double(v) >= rainThreshold else { continue }
                let dx = Double(x) - center.x, dy = Double(y) - center.y
                let d2 = dx * dx + dy * dy
                if best == nil || d2 < best!.d2 { best = (d2, dx, dy) }
            }
        }
        guard let best else { return nil }
        let bearing = (atan2(best.dx, -best.dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return (best.d2.squareRoot() * milesPerPixel, bearing)
    }

    /// Connected areas of heavy echo (≥ 40 dBZ) in the latest frame.
    /// `velocity` is echo motion in miles per minute, east and north.
    public static func detectCells(in field: ReflectivityField, viewport: RadarViewport,
                                   velocity: (east: Double, north: Double)) -> [StormCell] {
        let mpp = viewport.milesPerPixel
        let minimumPixels = max(2, Int((2.0 / (mpp * mpp)).rounded()))
        var visited = [Bool](repeating: false, count: field.width * field.height)
        var cells: [StormCell] = []
        let center = (x: Double(viewport.width) / 2 - 0.5, y: Double(viewport.height) / 2 - 0.5)

        for start in 0..<(field.width * field.height) {
            guard !visited[start], field.dbz[start] != ReflectivityField.none, Double(field.dbz[start]) >= heavyThreshold else { continue }
            var stack = [start]
            visited[start] = true
            var count = 0, sumX = 0.0, sumY = 0.0, maxDBZ: Int8 = .min
            while let index = stack.popLast() {
                count += 1
                let x = index % field.width, y = index / field.width
                sumX += Double(x); sumY += Double(y)
                maxDBZ = max(maxDBZ, field.dbz[index])
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    guard nx >= 0, ny >= 0, nx < field.width, ny < field.height else { continue }
                    let n = ny * field.width + nx
                    guard !visited[n], field.dbz[n] != ReflectivityField.none, Double(field.dbz[n]) >= heavyThreshold else { continue }
                    visited[n] = true
                    stack.append(n)
                }
            }
            guard count >= minimumPixels else { continue }
            let cx = sumX / Double(count), cy = sumY / Double(count)
            let east = (cx - center.x) * mpp, north = (center.y - cy) * mpp
            let distance = hypot(east, north)
            let coordinate = viewport.coordinate(x: cx, y: cy)
            let bearing = (atan2(east, north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            let area = Double(count) * mpp * mpp
            let cellRadius = (area / .pi).squareRoot()

            var approachMiles: Double?, approachMinutes: Int?, arrival: Int?
            let speed2 = velocity.east * velocity.east + velocity.north * velocity.north
            if speed2 > 1e-4 {
                let t = -(east * velocity.east + north * velocity.north) / speed2
                // Extrapolating a cell beyond a few hours is not meaningful.
                if t > 0, t <= Double(horizonMinutes) * 1.5 {
                    let px = east + velocity.east * t, py = north + velocity.north * t
                    let miss = hypot(px, py)
                    approachMiles = miss
                    approachMinutes = Int(t.rounded())
                    if miss <= cellRadius + 1 {
                        let back = ((cellRadius + 1) * (cellRadius + 1) - miss * miss).squareRoot() / speed2.squareRoot()
                        arrival = max(0, Int((t - back).rounded()))
                    }
                }
            }
            if distance <= cellRadius { arrival = 0 }
            cells.append(StormCell(id: cells.count + 1, latitude: coordinate.latitude, longitude: coordinate.longitude,
                                   distanceMiles: distance, bearing: bearing, maxDBZ: Double(maxDBZ),
                                   areaSquareMiles: area, closestApproachMiles: approachMiles,
                                   closestApproachMinutes: approachMinutes, arrivalMinutes: arrival))
        }
        // Most threatening first: arriving soonest, then nearest and strongest.
        return cells.sorted {
            let a = ($0.arrivalMinutes ?? 999, $0.distanceMiles - $0.maxDBZ / 10)
            let b = ($1.arrivalMinutes ?? 999, $1.distanceMiles - $1.maxDBZ / 10)
            return a < b
        }
        .prefix(8)
        .enumerated()
        .map { offset, cell in
            StormCell(id: offset + 1, latitude: cell.latitude, longitude: cell.longitude, distanceMiles: cell.distanceMiles,
                      bearing: cell.bearing, maxDBZ: cell.maxDBZ, areaSquareMiles: cell.areaSquareMiles,
                      closestApproachMiles: cell.closestApproachMiles, closestApproachMinutes: cell.closestApproachMinutes,
                      arrivalMinutes: cell.arrivalMinutes)
        }
    }
}
