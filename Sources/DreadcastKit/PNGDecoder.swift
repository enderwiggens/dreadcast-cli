import Foundation

/// An 8-bit RGBA image. Pixels are stored row-major without premultiplied alpha.
public struct RGBAImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// RGBA packed as 0xRRGGBBAA.
    @inline(__always)
    public func rgba(x: Int, y: Int) -> UInt32 {
        let i = (y * width + x) * 4
        return UInt32(pixels[i]) << 24 | UInt32(pixels[i + 1]) << 16 | UInt32(pixels[i + 2]) << 8 | UInt32(pixels[i + 3])
    }
}

/// A small PNG decoder for non-interlaced 8-bit images and indexed images.
/// Decoding palette entries exactly is what lets dreadcast recover radar dBZ.
public enum PNGDecoder {
    public enum Failure: Error, Equatable {
        case notPNG, unsupported(String), corrupt(String)
    }

    public static func decode(_ data: Data) throws -> RGBAImage {
        let bytes = [UInt8](data)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { throw Failure.notPNG }

        var offset = 8
        var width = 0, height = 0, bitDepth = 0, colorType = -1, interlace = 0
        var palette: [UInt8] = []
        var transparency: [UInt8] = []
        var compressed: [UInt8] = []

        func u32(_ i: Int) -> Int {
            Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
        }

        while offset + 8 <= bytes.count {
            let length = u32(offset)
            let typeStart = offset + 4
            let dataStart = offset + 8
            guard length >= 0, dataStart + length + 4 <= bytes.count else { throw Failure.corrupt("chunk length") }
            let type = String(bytes: bytes[typeStart..<typeStart + 4], encoding: .ascii) ?? ""
            let chunk = bytes[dataStart..<dataStart + length]
            switch type {
            case "IHDR":
                guard length == 13 else { throw Failure.corrupt("IHDR") }
                width = u32(dataStart)
                height = u32(dataStart + 4)
                bitDepth = Int(bytes[dataStart + 8])
                colorType = Int(bytes[dataStart + 9])
                interlace = Int(bytes[dataStart + 12])
            case "PLTE":
                palette = Array(chunk)
            case "tRNS":
                transparency = Array(chunk)
            case "IDAT":
                compressed.append(contentsOf: chunk)
            case "IEND":
                offset = bytes.count
                continue
            default:
                break
            }
            offset = dataStart + length + 4
        }

        guard width > 0, height > 0, width <= 8192, height <= 8192 else { throw Failure.corrupt("dimensions") }
        guard interlace == 0 else { throw Failure.unsupported("interlaced PNG") }

        let channels: Int
        switch colorType {
        case 0: channels = 1
        case 2: channels = 3
        case 3: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: throw Failure.unsupported("color type \(colorType)")
        }
        if colorType == 3 {
            guard [1, 2, 4, 8].contains(bitDepth) else { throw Failure.unsupported("palette depth \(bitDepth)") }
        } else {
            guard bitDepth == 8 else { throw Failure.unsupported("bit depth \(bitDepth)") }
        }

        let bitsPerPixel = channels * bitDepth
        let rowBytes = (width * bitsPerPixel + 7) / 8
        let filterStride = max(1, bitsPerPixel / 8)
        let expected = height * (rowBytes + 1)
        let raw = try inflate(compressed, expectedSize: expected)
        guard raw.count >= expected else { throw Failure.corrupt("image data") }

        // Undo per-scanline filters.
        var current = [UInt8](repeating: 0, count: rowBytes)
        var previous = [UInt8](repeating: 0, count: rowBytes)
        var output = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            let base = y * (rowBytes + 1)
            let filter = raw[base]
            for i in 0..<rowBytes {
                let x = raw[base + 1 + i]
                let a = i >= filterStride ? current[i - filterStride] : 0
                let b = previous[i]
                let c = i >= filterStride ? previous[i - filterStride] : 0
                switch filter {
                case 0: current[i] = x
                case 1: current[i] = x &+ a
                case 2: current[i] = x &+ b
                case 3: current[i] = x &+ UInt8((Int(a) + Int(b)) / 2)
                case 4: current[i] = x &+ paeth(a, b, c)
                default: throw Failure.corrupt("filter \(filter)")
                }
            }

            for xIndex in 0..<width {
                let o = (y * width + xIndex) * 4
                switch colorType {
                case 3:
                    let index: Int
                    if bitDepth == 8 {
                        index = Int(current[xIndex])
                    } else {
                        let bit = xIndex * bitDepth
                        let byte = current[bit / 8]
                        let shift = 8 - bitDepth - (bit % 8)
                        index = Int((byte >> UInt8(shift)) & UInt8((1 << bitDepth) - 1))
                    }
                    guard index * 3 + 2 < palette.count else { throw Failure.corrupt("palette index") }
                    output[o] = palette[index * 3]
                    output[o + 1] = palette[index * 3 + 1]
                    output[o + 2] = palette[index * 3 + 2]
                    output[o + 3] = index < transparency.count ? transparency[index] : 255
                case 0:
                    let v = current[xIndex]
                    output[o] = v; output[o + 1] = v; output[o + 2] = v; output[o + 3] = 255
                case 4:
                    let v = current[xIndex * 2]
                    output[o] = v; output[o + 1] = v; output[o + 2] = v; output[o + 3] = current[xIndex * 2 + 1]
                case 2:
                    output[o] = current[xIndex * 3]
                    output[o + 1] = current[xIndex * 3 + 1]
                    output[o + 2] = current[xIndex * 3 + 2]
                    output[o + 3] = 255
                default:
                    output[o] = current[xIndex * 4]
                    output[o + 1] = current[xIndex * 4 + 1]
                    output[o + 2] = current[xIndex * 4 + 2]
                    output[o + 3] = current[xIndex * 4 + 3]
                }
            }
            swap(&current, &previous)
        }
        return RGBAImage(width: width, height: height, pixels: output)
    }

    @inline(__always)
    private static func paeth(_ a: UInt8, _ b: UInt8, _ c: UInt8) -> UInt8 {
        let p = Int(a) + Int(b) - Int(c)
        let pa = abs(p - Int(a)), pb = abs(p - Int(b)), pc = abs(p - Int(c))
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }

    static func inflate(_ zlib: [UInt8], expectedSize: Int) throws -> [UInt8] {
        do {
            return try Inflate.zlib(zlib, expectedSize: expectedSize, maximumSize: expectedSize + 1024)
        } catch {
            throw Failure.corrupt("image data")
        }
    }
}
