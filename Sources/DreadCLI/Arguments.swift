import Foundation

/// Parsed command-line arguments. dreadcast has no external dependencies, so this
/// small parser replaces swift-argument-parser.
public struct Arguments: Sendable {
    public var command: String
    /// False when no command was typed, so `command` is the default.
    public var commandGiven = false
    public var positionals: [String] = []
    public var options: [String: String] = [:]
    public var flags: Set<String> = []

    public static let commands: Set<String> = [
        "now", "weather", "radar", "alerts", "prompt", "forecast", "outlook", "top", "lightning", "eta", "scene",
        "setup", "auth", "config", "credits", "refresh", "help", "version"
    ]

    static let valueOptions: Set<String> = [
        "location", "units", "range", "palette", "renderer", "frames", "loops", "hours", "fail-on",
        "radius", "format", "min-dbz", "interval", "width", "client-id", "client-secret", "time", "size", "png", "layout", "at"
    ]

    static let booleanFlags: Set<String> = [
        "json", "plain", "no-color", "help", "version", "still", "once", "follow", "watch", "quiet",
        "ascii", "no-quip", "all", "no-lightning", "debug", "pretty", "no-scene"
    ]

    static let shortOptions: [String: String] = [
        "h": "help", "V": "version", "j": "json", "l": "location", "r": "range", "p": "palette"
    ]

    public enum ParseError: LocalizedError, Equatable {
        case unknownOption(String)
        case missingValue(String)

        public var errorDescription: String? {
            switch self {
            case .unknownOption(let name): "Unknown option \(name). Run `dread help` for the options."
            case .missingValue(let name): "\(name) needs a value."
            }
        }
    }

    public init(command: String, positionals: [String] = [], options: [String: String] = [:], flags: Set<String> = []) {
        self.command = command
        self.positionals = positionals
        self.options = options
        self.flags = flags
    }

    public static func parse(_ arguments: [String]) throws -> Arguments {
        var result = Arguments(command: "now")
        var commandSet = false
        var index = 0
        func next(_ name: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.missingValue("--\(name)") }
            return arguments[index]
        }
        while index < arguments.count {
            let token = arguments[index]
            if token == "--" {
                result.positionals.append(contentsOf: arguments[(index + 1)...])
                break
            }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                let (name, inline) = body.split(separator: "=", maxSplits: 1).map(String.init).splitPair()
                if valueOptions.contains(name) {
                    result.options[name] = try inline ?? next(name)
                } else if booleanFlags.contains(name) {
                    result.flags.insert(name)
                } else {
                    throw ParseError.unknownOption(token)
                }
            } else if token.hasPrefix("-"), token.count > 1, Double(token) == nil, !token.contains(",") {
                let name = String(token.dropFirst())
                guard let long = shortOptions[name] else { throw ParseError.unknownOption(token) }
                if valueOptions.contains(long) { result.options[long] = try next(long) } else { result.flags.insert(long) }
            } else if !commandSet, result.positionals.isEmpty, commands.contains(token.lowercased()) {
                result.command = token.lowercased()
                commandSet = true
            } else {
                result.positionals.append(token)
            }
            index += 1
        }
        if result.flags.contains("version"), !commandSet { result.command = "version" }
        result.commandGiven = commandSet
        return result
    }

    public func value(_ name: String) -> String? { options[name] }
    public func has(_ flag: String) -> Bool { flags.contains(flag) }

    public func integer(_ name: String) -> Int? { options[name].flatMap { Int($0) } }
    public func double(_ name: String) -> Double? { options[name].flatMap { Double($0) } }
}

private extension Array where Element == String {
    func splitPair() -> (String, String?) {
        (self.first ?? "", self.count > 1 ? self[1] : nil)
    }
}
