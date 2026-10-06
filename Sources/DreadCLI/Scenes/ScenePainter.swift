import Foundation
import DreadcastKit
import DreadTerminal

/// Paints a scene as pixel art for one of three layouts. Scenes are drawn for the
/// terminal with the scene kit (see Kit/), at one pixel scale; very large terminals
/// double every pixel instead of stretching the art.
public struct ScenePainter: Sendable {
    public let scene: SceneID
    public let period: ScenePeriod
    /// Seconds of ambient motion. Loops are independent, so the scene never moves in unison.
    public let time: Double
    /// A composed frame for still output: brief accents such as lightning are posed, not timed.
    public let still: Bool
    public let moon: LunarPhase
    public let layout: SceneLayout

    public init(scene: SceneID, period: ScenePeriod, time: Double = 0, still: Bool = true, moon: LunarPhase,
                layout: SceneLayout = .window) {
        self.scene = scene
        self.period = period
        self.time = time
        self.still = still
        self.moon = moon
        self.layout = layout
    }

    static func draw(_ scene: SceneID) -> (inout Stage) -> Void {
        switch scene {
        case .asteroid: AsteroidWatch.draw
        case .deepTrouble: DeepTrouble.draw
        case .aiUprising: AIUprising.draw
        case .solarTantrum: SolarTantrum.draw
        case .fallout: FalloutOutlook.draw
        case .superstorm: Superstorm.draw
        case .clearForNow: ClearForNow.draw
        case .uap: UAPInvasion.draw
        }
    }

    public func paint(width: Int, height: Int) -> Raster {
        let scale = layout == .window ? Stage.scale(width: width, height: height) : 1
        var stage = Stage(width: max(1, width / scale), height: max(1, height / scale), layout: layout,
                          period: period, time: time, still: still, moon: moon)
        Self.draw(scene)(&stage)
        guard scale > 1 else { return stage.raster }
        var large = Raster(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width { large[x, y] = stage.raster[min(x / scale, stage.w - 1), min(y / scale, stage.h - 1)] }
        }
        return large
    }
}

/// Shared colors. Scene families follow the brand palette; other shades derive from them.
enum Ink {
    static let lamp: UInt32 = 0xFFCC9F
    static let lampHot: UInt32 = 0xFFE6C4
    static let porcelain: UInt32 = 0xEEF0F5
}
