import Compression
import Foundation

/// Just enough zip support to read GP7+ files and rewrite one entry while
/// copying every other entry's compressed bytes through unchanged.
struct ZipArchive {
    struct Entry {
        var name: String
        var nameBytes: Data
        var versionNeeded: UInt16
        var flags: UInt16
        var method: UInt16
        var time: UInt16
        var date: UInt16
        var crc: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
        var externalAttributes: UInt32
        var versionMadeBy: UInt16
        var compressed: Data
    }

    var entries: [Entry] = []

    init(_ data: Data) throws {
        let bytes = Data(data)
        guard bytes.count >= 22 else { throw TabError("Not a zip file") }
        var eocd = bytes.count - 22
        let minimum = max(0, bytes.count - 22 - 0xFFFF)
        while eocd >= minimum, bytes.uint32LE(at: eocd) != 0x0605_4B50 { eocd -= 1 }
        guard eocd >= minimum else { throw TabError("Zip directory not found") }

        let count = bytes.uint16LE(at: eocd + 10)
        var offset = bytes.uint32LE(at: eocd + 16)
        for _ in 0..<count {
            guard offset + 46 <= bytes.count, bytes.uint32LE(at: offset) == 0x0201_4B50 else {
                throw TabError("Corrupt zip directory")
            }
            let nameLength = bytes.uint16LE(at: offset + 28)
            let extraLength = bytes.uint16LE(at: offset + 30)
            let commentLength = bytes.uint16LE(at: offset + 32)
            let localOffset = bytes.uint32LE(at: offset + 42)
            let compressedSize = bytes.uint32LE(at: offset + 20)
            let nameBytes = bytes.subdata(in: offset + 46 ..< offset + 46 + nameLength)

            guard localOffset + 30 <= bytes.count, bytes.uint32LE(at: localOffset) == 0x0403_4B50 else {
                throw TabError("Corrupt zip entry")
            }
            let dataStart = localOffset + 30 + bytes.uint16LE(at: localOffset + 26) + bytes.uint16LE(at: localOffset + 28)
            guard dataStart + compressedSize <= bytes.count else { throw TabError("Truncated zip entry") }

            entries.append(Entry(
                name: String(decoding: nameBytes, as: UTF8.self),
                nameBytes: nameBytes,
                versionNeeded: UInt16(bytes.uint16LE(at: offset + 6)),
                flags: UInt16(bytes.uint16LE(at: offset + 8)),
                method: UInt16(bytes.uint16LE(at: offset + 10)),
                time: UInt16(bytes.uint16LE(at: offset + 12)),
                date: UInt16(bytes.uint16LE(at: offset + 14)),
                crc: UInt32(bytes.uint32LE(at: offset + 16)),
                compressedSize: compressedSize,
                uncompressedSize: bytes.uint32LE(at: offset + 24),
                externalAttributes: UInt32(bytes.uint32LE(at: offset + 38)),
                versionMadeBy: UInt16(bytes.uint16LE(at: offset + 4)),
                compressed: bytes.subdata(in: dataStart ..< dataStart + compressedSize)
            ))
            offset += 46 + nameLength + extraLength + commentLength
        }
    }

    func contents(of name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else { throw TabError("\(name) missing from archive") }
        switch entry.method {
        case 0: return entry.compressed
        case 8: return try Deflate.inflate(entry.compressed, size: entry.uncompressedSize)
        default: throw TabError("Unsupported zip compression method \(entry.method)")
        }
    }

    mutating func replace(_ name: String, with contents: Data) throws {
        guard let index = entries.firstIndex(where: { $0.name == name }) else { throw TabError("\(name) missing from archive") }
        var entry = entries[index]
        if let deflated = Deflate.deflate(contents) {
            entry.method = 8
            entry.compressed = deflated
        } else {
            entry.method = 0
            entry.compressed = contents
        }
        entry.versionNeeded = max(entry.versionNeeded, 20)
        entry.crc = CRC32.checksum(contents)
        entry.compressedSize = entry.compressed.count
        entry.uncompressedSize = contents.count
        entries[index] = entry
    }

    func serialized() -> Data {
        var out = ByteWriter()
        var localOffsets: [Int] = []
        for entry in entries {
            localOffsets.append(out.data.count)
            out.uint32(0x0403_4B50)
            out.uint16(entry.versionNeeded)
            out.uint16(entry.flags & ~0x0008) // sizes are known up front, so no data descriptor
            out.uint16(entry.method)
            out.uint16(entry.time)
            out.uint16(entry.date)
            out.uint32(entry.crc)
            out.uint32(UInt32(entry.compressedSize))
            out.uint32(UInt32(entry.uncompressedSize))
            out.uint16(UInt16(entry.nameBytes.count))
            out.uint16(0)
            out.append(entry.nameBytes)
            out.append(entry.compressed)
        }
        let directoryStart = out.data.count
        for (entry, localOffset) in zip(entries, localOffsets) {
            out.uint32(0x0201_4B50)
            out.uint16(entry.versionMadeBy)
            out.uint16(entry.versionNeeded)
            out.uint16(entry.flags & ~0x0008)
            out.uint16(entry.method)
            out.uint16(entry.time)
            out.uint16(entry.date)
            out.uint32(entry.crc)
            out.uint32(UInt32(entry.compressedSize))
            out.uint32(UInt32(entry.uncompressedSize))
            out.uint16(UInt16(entry.nameBytes.count))
            out.uint16(0) // extra
            out.uint16(0) // comment
            out.uint16(0) // disk
            out.uint16(0) // internal attributes
            out.uint32(entry.externalAttributes)
            out.uint32(UInt32(localOffset))
            out.append(entry.nameBytes)
        }
        let directorySize = out.data.count - directoryStart
        out.uint32(0x0605_4B50)
        out.uint16(0)
        out.uint16(0)
        out.uint16(UInt16(entries.count))
        out.uint16(UInt16(entries.count))
        out.uint32(UInt32(directorySize))
        out.uint32(UInt32(directoryStart))
        out.uint16(0)
        return out.data
    }
}

/// Raw (RFC 1951) deflate via Apple's Compression framework.
enum Deflate {
    static func inflate(_ data: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw TabError("Failed to decompress zip entry") }
        return output
    }

    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < data.count else { return nil }
        return output.prefix(written)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
