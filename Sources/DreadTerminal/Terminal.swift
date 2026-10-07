import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public enum ColorMode: Int, Comparable, Sendable {
    case none, ansi16, ansi256, truecolor

    public static func < (lhs: ColorMode, rhs: ColorMode) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum GraphicsProtocol: String, Sendable, CaseIterable {
    case none, kitty, iterm2
}

/// What the attached terminal can do, detected from the environment.
public struct TerminalInfo: Sendable {
    public var isOutputTTY: Bool
    public var isInputTTY: Bool
    public var columns: Int
    public var rows: Int
    public var colorMode: ColorMode
    public var graphics: GraphicsProtocol
    public var program: String?
    public var insideMultiplexer: Bool
    public var reduceMotion: Bool

    public init(isOutputTTY: Bool, isInputTTY: Bool, columns: Int, rows: Int, colorMode: ColorMode,
                graphics: GraphicsProtocol, program: String?, insideMultiplexer: Bool, reduceMotion: Bool) {
        self.isOutputTTY = isOutputTTY
        self.isInputTTY = isInputTTY
        self.columns = columns
        self.rows = rows
        self.colorMode = colorMode
        self.graphics = graphics
        self.program = program
        self.insideMultiplexer = insideMultiplexer
        self.reduceMotion = reduceMotion
    }

    public static func detect(environment: [String: String] = ProcessInfo.processInfo.environment) -> TerminalInfo {
        let outputTTY = isatty(STDOUT_FILENO) != 0
        let inputTTY = isatty(STDIN_FILENO) != 0
        let size = Self.windowSize() ?? (
            Int(environment["COLUMNS"] ?? "") ?? 80,
            Int(environment["LINES"] ?? "") ?? 24
        )
        return TerminalInfo(
            isOutputTTY: outputTTY,
            isInputTTY: inputTTY,
            columns: max(20, size.0),
            rows: max(8, size.1),
            colorMode: colorMode(environment: environment, isTTY: outputTTY),
            graphics: graphics(environment: environment, isTTY: outputTTY),
            program: environment["TERM_PROGRAM"],
            insideMultiplexer: environment["TMUX"] != nil || (environment["TERM"] ?? "").hasPrefix("screen"),
            reduceMotion: reduceMotion(environment: environment)
        )
    }

    public static func windowSize() -> (Int, Int)? {
        var size = winsize()
        for fd in [STDOUT_FILENO, STDERR_FILENO, STDIN_FILENO] {
            let result = withUnsafeMutablePointer(to: &size) { ioctl(fd, UInt(TIOCGWINSZ), $0) }
            if result == 0, size.ws_col > 0, size.ws_row > 0 {
                return (Int(size.ws_col), Int(size.ws_row))
            }
        }
        return nil
    }

    public static func colorMode(environment: [String: String], isTTY: Bool) -> ColorMode {
        if let value = environment["NO_COLOR"], !value.isEmpty { return .none }
        let forced = (environment["CLICOLOR_FORCE"].map { $0 != "0" } ?? false)
            || (environment["FORCE_COLOR"].map { !$0.isEmpty && $0 != "0" } ?? false)
        if !isTTY && !forced { return .none }
        let term = environment["TERM"] ?? ""
        if term == "dumb" { return .none }
        let colorTerm = (environment["COLORTERM"] ?? "").lowercased()
        if colorTerm == "truecolor" || colorTerm == "24bit" { return .truecolor }
        let program = environment["TERM_PROGRAM"] ?? ""
        if ["iTerm.app", "WezTerm", "ghostty", "vscode", "Hyper", "WarpTerminal", "rio", "Tabby"].contains(program) { return .truecolor }
        if term == "xterm-kitty" || term.contains("ghostty") || term.contains("direct") || term.contains("truecolor") { return .truecolor }
        if term.contains("256color") || program == "Apple_Terminal" { return .ansi256 }
        return forced ? .ansi256 : .ansi16
    }

    static func graphics(environment: [String: String], isTTY: Bool) -> GraphicsProtocol {
        if let forced = environment["DREAD_GRAPHICS"].flatMap({ GraphicsProtocol(rawValue: $0.lowercased()) }) { return forced }
        guard isTTY else { return .none }
        // Multiplexers usually drop graphics escape sequences.
        if environment["TMUX"] != nil || (environment["TERM"] ?? "").hasPrefix("screen") { return .none }
        let program = environment["TERM_PROGRAM"] ?? ""
        if environment["KITTY_WINDOW_ID"] != nil || environment["TERM"] == "xterm-kitty" { return .kitty }
        if program == "ghostty" || (environment["TERM"] ?? "").contains("ghostty") { return .kitty }
        if program == "iTerm.app" || environment["LC_TERMINAL"] == "iTerm2" || program == "WezTerm" { return .iterm2 }
        return .none
    }

    static func reduceMotion(environment: [String: String]) -> Bool {
        if let value = environment["DREAD_REDUCE_MOTION"] { return value != "0" && !value.isEmpty }
        #if os(macOS)
        return UserDefaults(suiteName: "com.apple.universalaccess")?.bool(forKey: "reduceMotion") ?? false
        #else
        return false
        #endif
    }
}

@inline(__always)
func systemWrite(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(fd, pointer, count)
    #elseif canImport(Glibc)
    return Glibc.write(fd, pointer, count)
    #else
    return Musl.write(fd, pointer, count)
    #endif
}

/// Escape sequences for cursor and screen control.
public enum TerminalControl {
    public static let hideCursor = "\u{1B}[?25l"
    public static let showCursor = "\u{1B}[?25h"
    public static let alternateScreenOn = "\u{1B}[?1049h"
    public static let alternateScreenOff = "\u{1B}[?1049l"
    public static let clearScreen = "\u{1B}[2J"
    public static let home = "\u{1B}[H"
    public static let clearLine = "\u{1B}[2K"
    public static let clearToEnd = "\u{1B}[0J"
    public static let focusReportingOn = "\u{1B}[?1004h"
    public static let focusReportingOff = "\u{1B}[?1004l"

    public static func moveUp(_ lines: Int) -> String { lines > 0 ? "\u{1B}[\(lines)A" : "" }
    public static func moveTo(row: Int, column: Int) -> String { "\u{1B}[\(row);\(column)H" }
    public static func column(_ column: Int) -> String { "\u{1B}[\(column)G" }
}

/// Unbuffered writes to standard output.
public enum Console {
    public static func write(_ text: String) {
        var text = text
        text.withUTF8 { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = systemWrite(STDOUT_FILENO, buffer.baseAddress! + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    public static func writeError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}

/// Keys read in raw mode.
public enum Key: Equatable, Sendable {
    case character(Character)
    case up, down, left, right, enter, escape, tab, backTab, backspace, interrupt
    case pageUp, pageDown, home, end
    case focusIn, focusOut
}

/// Raw-mode input and full-screen state with guaranteed restoration on exit and signals.
public final class RawTerminal: @unchecked Sendable {
    nonisolated(unsafe) private static var original: termios?
    nonisolated(unsafe) private static var raw: termios?
    nonisolated(unsafe) private static var restoreBytes: [UInt8] = []
    nonisolated(unsafe) private static var enterBytes: [UInt8] = []
    nonisolated(unsafe) private static var resumedFlag: Int32 = 0
    /// Keys already read but not yet returned, when several arrive together.
    private var pending: [Key] = []

    /// - Parameter cleanup: extra bytes written on exit or interruption, such as deleting an inline image.
    public init?(alternateScreen: Bool, cleanup: String = "") {
        guard isatty(STDIN_FILENO) != 0 else { return nil }
        var current = termios()
        guard tcgetattr(STDIN_FILENO, &current) == 0 else { return nil }
        RawTerminal.original = current
        var raw = current
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN)
        raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
        withUnsafeMutablePointer(to: &raw.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 0
                cc[Int(VTIME)] = 0
            }
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        RawTerminal.raw = raw
        var restore = cleanup + TerminalControl.showCursor + TerminalControl.focusReportingOff + "\u{1B}[0m"
        if alternateScreen { restore += TerminalControl.alternateScreenOff }
        RawTerminal.restoreBytes = Array(restore.utf8)
        let enter = (alternateScreen ? TerminalControl.alternateScreenOn : "") + TerminalControl.hideCursor + TerminalControl.focusReportingOn
        RawTerminal.enterBytes = Array(enter.utf8)
        Console.write(enter)
        RawTerminal.installSignalHandlers()
    }

    /// True once after the process was suspended (Ctrl-Z) and resumed: the screen needs
    /// a full redraw.
    public func takeResumed() -> Bool {
        defer { RawTerminal.resumedFlag = 0 }
        return RawTerminal.resumedFlag != 0
    }

    deinit { restore() }

    public func restore() {
        RawTerminal.restoreNow()
    }

    private static func restoreNow() {
        if var original = RawTerminal.original {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            RawTerminal.original = nil
        }
        if !restoreBytes.isEmpty {
            restoreBytes.withUnsafeBufferPointer { _ = systemWrite(STDOUT_FILENO, $0.baseAddress!, $0.count) }
            restoreBytes = []
        }
    }

    private static func installSignalHandlers() {
        let handler: @convention(c) (Int32) -> Void = { signal in
            RawTerminal.restoreNow()
            _exit(128 + signal)
        }
        signal(SIGINT, handler)
        signal(SIGTERM, handler)
        signal(SIGHUP, handler)
        signal(SIGTSTP, suspendHandler)
    }

    /// Ctrl-Z: hand the terminal back as it was, stop, and take it again on `fg`.
    private static let suspendHandler: @convention(c) (Int32) -> Void = { _ in
        if var original = RawTerminal.original { tcsetattr(STDIN_FILENO, TCSAFLUSH, &original) }
        RawTerminal.restoreBytes.withUnsafeBufferPointer { if let base = $0.baseAddress { _ = systemWrite(STDOUT_FILENO, base, $0.count) } }
        signal(SIGTSTP, SIG_DFL)
        // The signal is blocked while its handler runs; unblock it so raising it stops
        // the process now, instead of queueing it to re-enter this handler forever.
        var mask = sigset_t()
        #if canImport(Darwin)
        mask = sigset_t(1) << sigset_t(SIGTSTP - 1)
        #else
        sigemptyset(&mask)
        sigaddset(&mask, SIGTSTP)
        #endif
        sigprocmask(SIG_UNBLOCK, &mask, nil)
        raise(SIGTSTP)
        // Execution continues here after SIGCONT.
        signal(SIGTSTP, RawTerminal.suspendHandler)
        if var raw = RawTerminal.raw { tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) }
        RawTerminal.enterBytes.withUnsafeBufferPointer { if let base = $0.baseAddress { _ = systemWrite(STDOUT_FILENO, base, $0.count) } }
        RawTerminal.resumedFlag = 1
    }

    /// Waits up to `timeout` seconds for a key.
    public func readKey(timeout: Double) -> Key? {
        if !pending.isEmpty { return pending.removeFirst() }
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var bytes = readAvailable()
        // A lone Esc may be the start of a sequence split by a slow connection.
        if bytes == [27], poll(&descriptor, 1, 30) > 0 { bytes += readAvailable() }
        pending = Self.keys(bytes)
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    private func readAvailable() -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        return count > 0 ? Array(buffer[0..<count]) : []
    }

    /// Splits input into keys: several can arrive in one read when keys repeat or text
    /// is pasted.
    static func keys(_ bytes: [UInt8]) -> [Key] {
        var keys: [Key] = []
        var i = 0
        while i < bytes.count {
            var end = i + 1
            if bytes[i] == 27, i + 1 < bytes.count {
                if bytes[i + 1] == 91 {
                    // CSI: parameters, then a final byte from @ to ~.
                    end = i + 2
                    while end < bytes.count, !(0x40...0x7E).contains(bytes[end]) { end += 1 }
                    end = min(end + 1, bytes.count)
                } else if bytes[i + 1] == 79, i + 2 < bytes.count {
                    // SS3, which some terminals send for arrows, Home and End.
                    end = i + 3
                } else {
                    // Alt with a key arrives as Esc then the key: keep just the key, so
                    // Alt never reads as Esc.
                    i += 1
                    continue
                }
            } else if bytes[i] >= 0xC0 {
                // The rest of a UTF-8 character.
                let length = bytes[i] >= 0xF0 ? 4 : bytes[i] >= 0xE0 ? 3 : 2
                end = min(i + length, bytes.count)
            }
            if let key = parse(Array(bytes[i..<end])) { keys.append(key) }
            i = end
        }
        return keys
    }

    static func parse(_ bytes: [UInt8]) -> Key? {
        guard let first = bytes.first else { return nil }
        switch first {
        case 3: return .interrupt
        case 9: return .tab
        case 13, 10: return .enter
        case 127, 8: return .backspace
        case 27:
            if bytes.count == 1 { return .escape }
            if bytes.count == 3, bytes[1] == 79 {
                switch bytes[2] {
                case 65: return .up
                case 66: return .down
                case 67: return .right
                case 68: return .left
                case 70: return .end
                case 72: return .home
                default: return nil
                }
            }
            if bytes.count >= 3, bytes[1] == 91 {
                switch bytes[2] {
                case 65: return .up
                case 66: return .down
                case 67: return .right
                case 68: return .left
                case 70: return .end
                case 72: return .home
                case 73: return .focusIn
                case 79: return .focusOut
                case 90: return .backTab
                case 49 where bytes.count >= 4 && bytes[3] == 126: return .home
                case 52 where bytes.count >= 4 && bytes[3] == 126: return .end
                case 53 where bytes.count >= 4 && bytes[3] == 126: return .pageUp
                case 54 where bytes.count >= 4 && bytes[3] == 126: return .pageDown
                default: return nil
                }
            }
            return .escape
        default:
            let text = String(decoding: bytes, as: UTF8.self)
            return text.first.map(Key.character)
        }
    }
}

/// Restores the cursor if the process is interrupted during an inline animation.
public enum InterruptGuard {
    nonisolated(unsafe) private static var cleanup: [UInt8] = []

    public static func install(cleanup sequence: String) {
        cleanup = Array(sequence.utf8)
        let handler: @convention(c) (Int32) -> Void = { signal in
            InterruptGuard.cleanup.withUnsafeBufferPointer { _ = systemWrite(STDOUT_FILENO, $0.baseAddress!, $0.count) }
            _exit(128 + signal)
        }
        signal(SIGINT, handler)
        signal(SIGTERM, handler)
    }

    public static func clear() {
        cleanup = []
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
