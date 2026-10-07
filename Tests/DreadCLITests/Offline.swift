import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import DreadcastKit
@testable import DreadCLI

/// Fails every request as if offline, so views that load in the background never reach
/// the network during tests.
final class OfflineProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}

    static var http: HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        return HTTPClient(session: URLSession(configuration: configuration))
    }
}

extension RadarPanel {
    /// A one-frame loop of the built-in basemap at any size, for tests.
    static func basemapLoop(_ place: Place, width: Int, rows: Int, units: UnitSystem = .imperial) -> Loop {
        let viewport = RadarViewport(center: place.coordinate, rangeMiles: 35, width: width, height: rows * 2)
        let scene = RadarScene(viewport: viewport, palette: .dreadcast, minimumDBZ: 15, units: units)
        return Loop(place: Context.placeKey(place), key: "\(Context.placeKey(place)) \(width)x\(rows)x35.0", scene: scene,
                    frames: [scene.base()], times: [Date()], loadedAt: Date())
    }
}
