import Foundation

/// GP3 / GP4 / GP5 binary files.
///
/// Layout: a 31-byte version block, then the song-info strings, then a notice
/// list, then the rest of the song. Only the info block is ever rewritten; every
/// byte after it is copied through untouched.
enum LegacyFormat {
    struct Header {
        var version: Int
        /// Raw string payloads, in file order, so unchanged fields round-trip byte-for-byte.
        var fields: [(Field, Data)]
        var notices: [Data]
        var end: Int
    }

    static func fieldOrder(version: Int) -> [Field] {
        version >= 5
            ? [.title, .subtitle, .artist, .album, .words, .music, .copyright, .tabber, .instructions]
            : [.title, .subtitle, .artist, .album, .words, .copyright, .tabber, .instructions]
    }

    static func supportedFields(version: Int) -> Set<Field> {
        Set(fieldOrder(version: version) + [.notices])
    }

    static func version(of data: Data) -> Int? {
        guard data.count > 31 else { return nil }
        let length = Int(data[data.startIndex])
        guard length <= 30 else { return nil }
        let text = String(decoding: data[data.startIndex + 1 ..< data.startIndex + 1 + length], as: UTF8.self)
        guard text.hasPrefix("FICHIER GUITAR PRO v") else { return nil }
        if text.contains("v3.") { return 3 }
        if text.contains("v4.") { return 4 }
        if text.contains("v5.") { return 5 }
        return nil
    }

    static func parseHeader(_ data: Data) throws -> Header {
        guard let version = version(of: data) else { throw TabError("Unrecognized Guitar Pro 3–5 header") }
        var reader = ByteReader(data)
        reader.offset = 31
        var fields: [(Field, Data)] = []
        for field in fieldOrder(version: version) {
            fields.append((field, try readIntByteSizeString(&reader)))
        }
        let noticeCount = try reader.int32()
        guard (0...10_000).contains(noticeCount) else { throw TabError("Corrupt notice count \(noticeCount)") }
        var notices: [Data] = []
        for _ in 0..<noticeCount {
            notices.append(try readIntByteSizeString(&reader))
        }
        return Header(version: version, fields: fields, notices: notices, end: reader.offset)
    }

    static func read(_ data: Data) throws -> TabMetadata {
        let header = try parseHeader(data)
        var meta = TabMetadata()
        for (field, raw) in header.fields { meta[field] = decode(raw) }
        meta[.notices] = header.notices.map(decode).joined(separator: "\n")
        return meta
    }

    static func apply(_ changes: [Field: String], to data: Data) throws -> Data {
        var header = try parseHeader(data)
        for index in header.fields.indices {
            let field = header.fields[index].0
            if let value = changes[field] { header.fields[index].1 = encode(value) }
        }
        if let notices = changes[.notices] {
            header.notices = notices.isEmpty ? [] : notices.components(separatedBy: "\n").map(encode)
        }

        var out = ByteWriter()
        out.append(data[data.startIndex ..< data.startIndex + 31])
        for (_, raw) in header.fields { writeIntByteSizeString(&out, raw) }
        out.int32(Int32(header.notices.count))
        for raw in header.notices { writeIntByteSizeString(&out, raw) }
        out.append(data[(data.startIndex + header.end)...])
        return out.data
    }

    // An int32 total size, then a byte length, then the characters.
    private static func readIntByteSizeString(_ reader: inout ByteReader) throws -> Data {
        let size = Int(try reader.int32()) - 1
        let length = Int(try reader.uint8())
        let stored = size >= 0 ? size : length
        let bytes = try reader.bytes(stored)
        return bytes.prefix(min(length, stored))
    }

    private static func writeIntByteSizeString(_ writer: inout ByteWriter, _ raw: Data) {
        writer.int32(Int32(raw.count + 1))
        writer.uint8(UInt8(raw.count))
        writer.append(raw)
    }

    static func decode(_ raw: Data) -> String {
        String(data: raw, encoding: .windowsCP1252) ?? String(data: raw, encoding: .isoLatin1) ?? ""
    }

    /// Strings are Windows-1252 and limited to 255 bytes by the byte length prefix.
    static func encode(_ value: String) -> Data {
        let data = value.data(using: .windowsCP1252, allowLossyConversion: true) ?? Data()
        return data.prefix(255)
    }
}

struct ByteReader {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw TabError("Unexpected end of file") }
        let start = data.startIndex + offset
        offset += count
        return data[start ..< start + count]
    }

    mutating func uint8() throws -> UInt8 { try bytes(1).first! }

    mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

    mutating func uint32() throws -> UInt32 {
        let b = try bytes(4)
        return b.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}

struct ByteWriter {
    var data = Data()

    mutating func append(_ bytes: Data) { data.append(bytes) }
    mutating func uint8(_ value: UInt8) { data.append(value) }
    mutating func int32(_ value: Int32) { uint32(UInt32(bitPattern: value)) }
    mutating func uint16(_ value: UInt16) { data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8)]) }
    mutating func uint32(_ value: UInt32) {
        data.append(contentsOf: [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)])
    }
}

extension Data {
    func uint16LE(at offset: Int) -> Int {
        Int(self[startIndex + offset]) | Int(self[startIndex + offset + 1]) << 8
    }

    func uint32LE(at offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | Int(self[startIndex + offset + $1]) << (8 * $1) }
    }
}
