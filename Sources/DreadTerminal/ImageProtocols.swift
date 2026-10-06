import Foundation
#if canImport(Compression)
import Compression
#endif

/// Minimal PNG encoder (8-bit RGB) for terminal image protocols.
public enum PNGEncoder {
    public static func encode(_ raster: Raster) -> Data? {
        var raw = [UInt8]()
        raw.reserveCapacity(raster.height * (raster.width * 3 + 1))
        for y in 0..<raster.height {
            raw.append(0) // filter: none
            for x in 0..<raster.width {
                let p = raster[x, y]
                raw.append(UInt8((p >> 16) & 0xFF))
                raw.append(UInt8((p >> 8) & 0xFF))
                raw.append(UInt8(p & 0xFF))
            }
        }
        guard let compressed = zlib(raw) else { return nil }
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var header = Data()
        header.append(contentsOf: bigEndian(UInt32(raster.width)))
        header.append(contentsOf: bigEndian(UInt32(raster.height)))
        header.append(contentsOf: [8, 2, 0, 0, 0]) // 8-bit RGB, deflate, no filter set, no interlace
        png.append(chunk("IHDR", header))
        png.append(chunk("IDAT", compressed))
        png.append(chunk("IEND", Data()))
        return png
    }

    private static func zlib(_ bytes: [UInt8]) -> Data? {
        #if canImport(Compression)
        var destination = [UInt8](repeating: 0, count: bytes.count + 1024)
        let written = bytes.withUnsafeBufferPointer { src in
            destination.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        var data = Data([0x78, 0x9C]) // zlib header around raw DEFLATE
        data.append(contentsOf: destination[0..<written])
        data.append(contentsOf: bigEndian(adler32(bytes)))
        return data
        #else
        return nil
        #endif
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return b << 16 | a
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }

    private static func chunk(_ type: String, _ body: Data) -> Data {
        var data = Data(bigEndian(UInt32(body.count)))
        var typed = Data(type.utf8)
        typed.append(body)
        data.append(typed)
        data.append(contentsOf: bigEndian(crc32(typed)))
        return data
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

/// Kitty graphics protocol, also implemented by Ghostty.
public enum KittyGraphics {
    /// Transmits and displays `png` scaled into `columns`×`rows` cells at the cursor.
    /// Re-sending the same `id` replaces the previous image, which animates in place.
    public static func display(png: Data, id: Int, columns: Int, rows: Int) -> String {
        let payload = png.base64EncodedString()
        var output = ""
        var offset = payload.startIndex
        var first = true
        while offset < payload.endIndex {
            let end = payload.index(offset, offsetBy: 4096, limitedBy: payload.endIndex) ?? payload.endIndex
            let more = end < payload.endIndex ? 1 : 0
            let control = first
                ? "a=T,f=100,i=\(id),c=\(columns),r=\(rows),C=1,q=2,m=\(more)"
                : "m=\(more)"
            output += "\u{1B}_G\(control);\(payload[offset..<end])\u{1B}\\"
            offset = end
            first = false
        }
        return output
    }

    public static func delete(id: Int) -> String {
        "\u{1B}_Ga=d,d=I,i=\(id),q=2\u{1B}\\"
    }
}

/// iTerm2 inline images, also implemented by WezTerm.
public enum ITermImages {
    public static func display(png: Data, columns: Int, rows: Int) -> String {
        "\u{1B}]1337;File=inline=1;size=\(png.count);width=\(columns);height=\(rows);preserveAspectRatio=0:" + png.base64EncodedString() + "\u{07}"
    }
}

public enum Charts {
    static let eighths: [Character] = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
    static let horizontalEighths: [Character] = ["▏", "▎", "▍", "▌", "▋", "▊", "▉", "█"]

    /// One block character for a fraction of the cell height (0–1).
    public static func block(_ fraction: Double, minimum: Bool = false) -> Character {
        let level = Int((max(0, min(1, fraction)) * 8).rounded())
        if level == 0 && minimum { return "▁" }
        return eighths[level]
    }

    /// The character for row `row` (0 = bottom) of a bar `rows` tall filled to `fraction`.
    public static func block(_ fraction: Double, row: Int, of rows: Int) -> Character {
        let filled = max(0, min(1, fraction)) * Double(rows) - Double(row)
        return eighths[Int((max(0, min(1, filled)) * 8).rounded())]
    }

    /// A horizontal bar `width` cells long using eighth blocks.
    public static func bar(_ fraction: Double, width: Int) -> String {
        let total = max(0, min(1, fraction)) * Double(width)
        let full = Int(total)
        let remainder = Int(((total - Double(full)) * 8).rounded())
        var result = String(repeating: "█", count: min(width, full))
        if full < width, remainder > 0 { result.append(horizontalEighths[remainder - 1]) }
        return result
    }

    public static func sparkline(_ values: [Double?], minimum: Double, maximum: Double) -> String {
        String(values.map { value -> Character in
            guard let value else { return " " }
            let span = max(0.0001, maximum - minimum)
            return block((value - minimum) / span, minimum: true)
        })
    }
}
