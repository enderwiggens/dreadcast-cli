import Foundation

/// A small, portable DEFLATE decoder (RFC 1951), so PNG decoding works the same on
/// macOS and Linux without Apple's Compression framework or a zlib dependency.
/// The structure follows Mark Adler's public-domain `puff.c` reference decoder.
public enum Inflate {
    public enum Failure: Error, Equatable {
        case truncated, invalidBlock, invalidCode, invalidDistance, tooLarge
    }

    /// Decodes a zlib stream (RFC 1950): a two-byte header, DEFLATE data and an Adler-32 trailer.
    public static func zlib(_ data: [UInt8], expectedSize: Int? = nil, maximumSize: Int = 64 * 1024 * 1024) throws -> [UInt8] {
        guard data.count >= 6 else { throw Failure.truncated }
        let cmf = data[0], flags = data[1]
        guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flags)) % 31 == 0, flags & 0x20 == 0 else { throw Failure.invalidBlock }
        return try raw(Array(data[2...]), expectedSize: expectedSize, maximumSize: maximumSize)
    }

    /// Decodes raw DEFLATE data.
    public static func raw(_ data: [UInt8], expectedSize: Int? = nil, maximumSize: Int = 64 * 1024 * 1024) throws -> [UInt8] {
        var state = State(input: data, maximumSize: maximumSize)
        if let expectedSize { state.output.reserveCapacity(expectedSize) }
        var last = false
        repeat {
            last = try state.bits(1) == 1
            switch try state.bits(2) {
            case 0: try state.stored()
            case 1: try state.codes(lengths: fixed.lengths, distances: fixed.distances)
            case 2:
                let tables = try state.dynamicTables()
                try state.codes(lengths: tables.0, distances: tables.1)
            default: throw Failure.invalidBlock
            }
        } while !last
        return state.output
    }

    struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]

        init(lengths: [Int]) throws {
            symbol = [Int](repeating: 0, count: lengths.count)
            for length in lengths { count[length] += 1 }
            var left = 1
            for length in 1...15 {
                left <<= 1
                left -= count[length]
                if left < 0 { throw Failure.invalidCode } // over-subscribed
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 { offsets[length + 1] = offsets[length] + count[length] }
            for (value, length) in lengths.enumerated() where length != 0 {
                symbol[offsets[length]] = value
                offsets[length] += 1
            }
        }
    }

    static let fixed: (lengths: Huffman, distances: Huffman) = {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        return (try! Huffman(lengths: lengths), try! Huffman(lengths: [Int](repeating: 5, count: 30)))
    }()

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                               2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    struct State {
        let input: [UInt8]
        let maximumSize: Int
        var position = 0
        var bitBuffer = 0
        var bitCount = 0
        var output: [UInt8] = []

        init(input: [UInt8], maximumSize: Int) {
            self.input = input
            self.maximumSize = maximumSize
        }

        mutating func bits(_ needed: Int) throws -> Int {
            var value = bitBuffer
            while bitCount < needed {
                guard position < input.count else { throw Failure.truncated }
                value |= Int(input[position]) << bitCount
                position += 1
                bitCount += 8
            }
            bitBuffer = value >> needed
            bitCount -= needed
            return value & ((1 << needed) - 1)
        }

        mutating func stored() throws {
            bitBuffer = 0
            bitCount = 0
            guard position + 4 <= input.count else { throw Failure.truncated }
            let length = Int(input[position]) | Int(input[position + 1]) << 8
            let complement = Int(input[position + 2]) | Int(input[position + 3]) << 8
            guard length == ~complement & 0xFFFF else { throw Failure.invalidBlock }
            position += 4
            guard position + length <= input.count else { throw Failure.truncated }
            guard output.count + length <= maximumSize else { throw Failure.tooLarge }
            output.append(contentsOf: input[position..<position + length])
            position += length
        }

        mutating func decode(_ table: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for length in 1...15 {
                code |= try bits(1)
                let count = table.count[length]
                if code - count < first { return table.symbol[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw Failure.invalidCode
        }

        mutating func codes(lengths: Huffman, distances: Huffman) throws {
            while true {
                let symbol = try decode(lengths)
                if symbol < 256 {
                    guard output.count < maximumSize else { throw Failure.tooLarge }
                    output.append(UInt8(symbol))
                } else if symbol == 256 {
                    return
                } else {
                    let lengthIndex = symbol - 257
                    guard lengthIndex < 29 else { throw Failure.invalidCode }
                    let length = Inflate.lengthBase[lengthIndex] + (try bits(Inflate.lengthExtra[lengthIndex]))
                    let distanceSymbol = try decode(distances)
                    guard distanceSymbol < 30 else { throw Failure.invalidDistance }
                    let distance = Inflate.distanceBase[distanceSymbol] + (try bits(Inflate.distanceExtra[distanceSymbol]))
                    guard distance <= output.count else { throw Failure.invalidDistance }
                    guard output.count + length <= maximumSize else { throw Failure.tooLarge }
                    let start = output.count - distance
                    for offset in 0..<length { output.append(output[start + offset]) }
                }
            }
        }

        mutating func dynamicTables() throws -> (Huffman, Huffman) {
            let literalCount = try bits(5) + 257
            let distanceCount = try bits(5) + 1
            let codeCount = try bits(4) + 4
            guard literalCount <= 286, distanceCount <= 30 else { throw Failure.invalidBlock }
            var codeLengths = [Int](repeating: 0, count: 19)
            for i in 0..<codeCount { codeLengths[Inflate.codeLengthOrder[i]] = try bits(3) }
            let codeTable = try Huffman(lengths: codeLengths)

            var lengths = [Int](repeating: 0, count: literalCount + distanceCount)
            var index = 0
            while index < lengths.count {
                let symbol = try decode(codeTable)
                if symbol < 16 {
                    lengths[index] = symbol
                    index += 1
                    continue
                }
                var repeatValue = 0
                let repeatCount: Int
                switch symbol {
                case 16:
                    guard index > 0 else { throw Failure.invalidBlock }
                    repeatValue = lengths[index - 1]
                    repeatCount = 3 + (try bits(2))
                case 17: repeatCount = 3 + (try bits(3))
                default: repeatCount = 11 + (try bits(7))
                }
                guard index + repeatCount <= lengths.count else { throw Failure.invalidBlock }
                for _ in 0..<repeatCount {
                    lengths[index] = repeatValue
                    index += 1
                }
            }
            guard lengths[256] != 0 else { throw Failure.invalidBlock } // no end-of-block code
            return (try Huffman(lengths: Array(lengths[0..<literalCount])),
                    try Huffman(lengths: Array(lengths[literalCount...])))
        }
    }
}
