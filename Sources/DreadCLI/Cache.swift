import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DreadcastKit
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// One cache shared by every shell. Values are JSON envelopes written atomically.
public final class DiskCache: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    struct Envelope<Value: Codable>: Codable {
        let storedAt: Date
        let value: Value
    }

    public func read<Value: Codable>(_ type: Value.Type, key: String) -> (value: Value, storedAt: Date)? {
        guard let data = try? Data(contentsOf: url(for: key)),
              let envelope = try? JSONDecoder.dreadcast.decode(Envelope<Value>.self, from: data) else { return nil }
        return (envelope.value, envelope.storedAt)
    }

    public func write<Value: Codable>(_ value: Value, key: String, at date: Date = Date()) {
        guard let data = try? JSONEncoder().encodeEnvelope(Envelope(storedAt: date, value: value)) else { return }
        try? data.write(to: url(for: key), options: .atomic)
    }

    public func remove(key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    func url(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" }
        return directory.appendingPathComponent(String(safe) + ".json")
    }

    /// Runs `body` only if no other dreadcast process holds the named lock.
    public func withExclusiveLock<T>(_ name: String, _ body: () throws -> T) rethrows -> T? {
        let path = directory.appendingPathComponent(name + ".lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return try body() }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return nil }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

private extension JSONEncoder {
    func encodeEnvelope<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder.dreadcast
        encoder.outputFormatting = []
        return try encoder.encode(value)
    }
}

/// Raw RainViewer tiles on disk. Frame paths are immutable, so entries stay
/// valid until the frame ages out; anything older than three hours is pruned.
public final class DiskTileStore: RadarTileStore, @unchecked Sendable {
    let directory: URL

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        prune()
    }

    public func tileData(for key: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(key + ".png"))
    }

    public func storeTile(_ data: Data, for key: String) {
        try? data.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
    }

    func prune() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3 * 3600)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}

/// A value from the cache or the network, with how old it is and what went wrong.
public struct Fetched<Value: Sendable>: Sendable {
    public let value: Value?
    public let storedAt: Date?
    public let error: String?
    /// True when the value is older than its refresh interval because a refresh failed.
    public let isStale: Bool

    public init(value: Value?, storedAt: Date?, error: String?, isStale: Bool) {
        self.value = value
        self.storedAt = storedAt
        self.error = error
        self.isStale = isStale
    }

    public static func failure(_ message: String) -> Fetched { Fetched(value: nil, storedAt: nil, error: message, isStale: false) }
}

extension Error {
    var userMessage: String {
        if let error = self as? LocalizedError, let description = error.errorDescription { return description }
        if let error = self as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: return "No internet connection."
            case .timedOut: return "The request timed out."
            case .cannotFindHost, .dnsLookupFailed: return "The service couldn’t be reached."
            default: return "The network request failed."
            }
        }
        return "Something went wrong."
    }
}
