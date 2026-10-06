import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum Dreadcast {
    public static let version = "0.1.0"
    public static let repositoryURL = "https://github.com/enderwiggens/dreadcast-cli"
    /// NWS asks every client to identify itself with a way to reach its maintainers.
    public static let userAgent = "dreadcast-cli/\(version) (+\(repositoryURL))"
}

public enum DreadcastError: LocalizedError, Equatable, Sendable {
    case httpStatus(Int, host: String)
    case invalidResponse(String)
    case oversized(String)
    case unavailable(String)
    case notFound(String)
    case unsupportedRegion(String)
    case missingCredentials(String)
    case unsupportedPlatform(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let status, let host): return "\(host) returned HTTP \(status)."
        case .invalidResponse(let source): return "\(source) returned a response dreadcast couldn’t read."
        case .oversized(let source): return "\(source) returned more data than expected."
        case .unavailable(let message): return message
        case .notFound(let message): return message
        case .unsupportedRegion(let message): return message
        case .missingCredentials(let message): return message
        case .unsupportedPlatform(let message): return message
        }
    }
}

/// A small URLSession wrapper with an identifying User-Agent, timeouts and size limits.
public struct HTTPClient: Sendable {
    public let session: URLSession
    public let userAgent: String

    public init(session: URLSession? = nil, userAgent: String = Dreadcast.userAgent) {
        if let session {
            self.session = session
        } else {
            // dreadcast keeps its own cache; avoid URLCache writing alongside it.
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 45
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
        self.userAgent = userAgent
    }

    public func data(
        _ url: URL,
        accept: String? = nil,
        timeout: TimeInterval = 15,
        maximumBytes: Int = 8 * 1024 * 1024,
        source: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        let label = source ?? url.host ?? "The service"
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DreadcastError.invalidResponse(label) }
        guard (200...299).contains(http.statusCode) else {
            throw DreadcastError.httpStatus(http.statusCode, host: url.host ?? label)
        }
        guard data.count <= maximumBytes else { throw DreadcastError.oversized(label) }
        return data
    }

    public func json<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        accept: String? = "application/json",
        timeout: TimeInterval = 15,
        maximumBytes: Int = 8 * 1024 * 1024,
        source: String? = nil
    ) async throws -> T {
        let data = try await self.data(url, accept: accept, timeout: timeout, maximumBytes: maximumBytes, source: source)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DreadcastError.invalidResponse(source ?? url.host ?? "The service")
        }
    }
}

enum ISODate {
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}
