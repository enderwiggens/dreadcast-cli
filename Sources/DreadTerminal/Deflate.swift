import Foundation

/// A small, portable DEFLATE encoder (RFC 1951) using LZ77 with fixed Huffman codes.
/// Radar and basemap images are mostly flat color, so repeated runs compress well
/// without dynamic Huffman tables. Works on every platform without zlib.
public enum Deflate {
    /// Compresses `input` into a zlib stream (RFC 1950).
    public static func zlib(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = [0x78, 0x9C]
        output.append(contentsOf: raw(input))
        let checksum = adler32(input)
        output.append(contentsOf: [UInt8(checksum >> 24), UInt8((checksum >> 16) & 0xFF), UInt8((checksum >> 8) & 0xFF), UInt8(checksum & 0xFF)])
        return output
    }

    /// One final block of fixed-Huffman DEFLATE data.
    public static func raw(_ input: [UInt8]) -> [UInt8] {
        var writer = BitWriter()
        writer.write(1, count: 1) // BFINAL
        writer.write(1, count: 2) // BTYPE = fixed Huffman

        let windowSize = 32_768, maximumMatch = 258, minimumMatch = 3, maximumChain = 48
        let hashSize = 1 << 15
        var head = [Int](repeating: -1, count: hashSize)
        var previous = [Int](repeating: -1, count: input.count)

        @inline(__always) func hash(_ i: Int) -> Int {
            ((Int(input[i]) << 10) ^ (Int(input[i + 1]) << 5) ^ Int(input[i + 2])) & (hashSize - 1)
        }
        @inline(__always) func insert(_ i: Int) {
            guard i + 2 < input.count else { return }
            let h = hash(i)
            previous[i] = head[h]
            head[h] = i
        }

        var i = 0
        while i < input.count {
            var bestLength = 0, bestDistance = 0
            if i + 2 < input.count {
                var candidate = head[hash(i)]
                var chain = 0
                let limit = min(maximumMatch, input.count - i)
                while candidate >= 0, i - candidate <= windowSize, chain < maximumChain {
                    var length = 0
                    while length < limit, input[candidate + length] == input[i + length] { length += 1 }
                    if length > bestLength {
                        bestLength = length
                        bestDistance = i - candidate
                        if length == limit { break }
                    }
                    candidate = previous[candidate]
                    chain += 1
                }
            }
            if bestLength >= minimumMatch {
                writeLength(bestLength, to: &writer)
                writeDistance(bestDistance, to: &writer)
                for offset in 0..<bestLength { insert(i + offset) }
                i += bestLength
            } else {
                writeLiteral(Int(input[i]), to: &writer)
                insert(i)
                i += 1
            }
        }
        writeLiteral(256, to: &writer) // end of block
        return writer.finish()
    }

    // Fixed Huffman literal/length codes (RFC 1951 §3.2.6), written most significant bit first.
    static func writeLiteral(_ symbol: Int, to writer: inout BitWriter) {
        switch symbol {
        case 0...143: writer.writeCode(0x30 + symbol, length: 8)
        case 144...255: writer.writeCode(0x190 + symbol - 144, length: 9)
        case 256...279: writer.writeCode(symbol - 256, length: 7)
        default: writer.writeCode(0xC0 + symbol - 280, length: 8)
        }
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                               2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    static func writeLength(_ length: Int, to writer: inout BitWriter) {
        var index = lengthBase.count - 1
        while lengthBase[index] > length { index -= 1 }
        writeLiteral(257 + index, to: &writer)
        if lengthExtra[index] > 0 { writer.write(length - lengthBase[index], count: lengthExtra[index]) }
    }

    static func writeDistance(_ distance: Int, to writer: inout BitWriter) {
        var index = distanceBase.count - 1
        while distanceBase[index] > distance { index -= 1 }
        writer.writeCode(index, length: 5)
        if distanceExtra[index] > 0 { writer.write(distance - distanceBase[index], count: distanceExtra[index]) }
    }

    static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        var index = 0
        while index < bytes.count {
            // Defer the modulo: 5552 is the largest run that cannot overflow UInt32.
            let end = min(bytes.count, index + 5552)
            while index < end {
                a += UInt32(bytes[index])
                b += a
                index += 1
            }
            a %= 65521
            b %= 65521
        }
        return b << 16 | a
    }

    struct BitWriter {
        var bytes: [UInt8] = []
        var buffer = 0
        var count = 0

        /// Writes `value` least significant bit first, as DEFLATE stores data fields.
        mutating func write(_ value: Int, count bits: Int) {
            buffer |= (value & ((1 << bits) - 1)) << count
            count += bits
            while count >= 8 {
                bytes.append(UInt8(buffer & 0xFF))
                buffer >>= 8
                count -= 8
            }
        }

        /// Writes a Huffman code most significant bit first.
        mutating func writeCode(_ code: Int, length: Int) {
            var reversed = 0
            for bit in 0..<length where code & (1 << bit) != 0 { reversed |= 1 << (length - 1 - bit) }
            write(reversed, count: length)
        }

        mutating func finish() -> [UInt8] {
            if count > 0 { bytes.append(UInt8(buffer & 0xFF)) }
            buffer = 0
            count = 0
            return bytes
        }
    }
}
