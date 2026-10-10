import Foundation

/// Guitar Pro 6 `.gpx` container.
///
/// A gpx file is "BCFZ" + a bit-packed LZ stream that decompresses to a "BCFS"
/// image: a tiny filesystem made of 4 KB sectors. Each file has an entry
/// sector (type 2, name, size, list of data sector indices) followed by its
/// data sectors. The song lives in `score.gpif`.
struct GPXArchive {
    static let sectorSize = 0x1000

    struct File {
        var entrySector: Data
        var name: String
        var contents: Data
    }

    var headerSector: Data
    var files: [File] = []

    init(_ data: Data) throws {
        let image: Data
        switch String(decoding: data.prefix(4), as: UTF8.self) {
        case "BCFZ": image = try BCFZ.decompress(data)
        case "BCFS": image = Data(data)
        default: throw TabError("Not a Guitar Pro 6 file")
        }
        // Sector indices are relative to the image without its "BCFS" magic.
        var fs = Data(image.dropFirst(4))
        if fs.count % Self.sectorSize != 0 { fs.append(Data(count: Self.sectorSize - fs.count % Self.sectorSize)) }
        let size = Self.sectorSize
        guard fs.count >= size else { throw TabError("Truncated GPX image") }
        headerSector = fs.prefix(size)

        var offset = size
        while offset + size <= fs.count {
            if fs.uint32LE(at: offset) == 2 {
                let entry = fs.subdata(in: offset ..< offset + size)
                let nameBytes = entry.subdata(in: 4 ..< 4 + 127).prefix { $0 != 0 }
                let fileSize = entry.uint32LE(at: 0x8C)
                var contents = Data()
                var pointer = 0x94
                while pointer + 4 <= size {
                    let sector = entry.uint32LE(at: pointer)
                    if sector == 0 { break }
                    let start = sector * size
                    guard start + size <= fs.count else { throw TabError("GPX sector out of range") }
                    contents.append(fs.subdata(in: start ..< start + size))
                    offset = start
                    pointer += 4
                }
                guard contents.count >= fileSize else { throw TabError("GPX file shorter than declared") }
                files.append(File(entrySector: entry, name: String(decoding: nameBytes, as: UTF8.self),
                                  contents: contents.prefix(fileSize)))
            }
            offset += size
        }
    }

    func contents(of name: String) throws -> Data {
        guard let file = files.first(where: { $0.name == name }) else { throw TabError("\(name) missing from GPX") }
        return file.contents
    }

    mutating func replace(_ name: String, with contents: Data) throws {
        guard let index = files.firstIndex(where: { $0.name == name }) else { throw TabError("\(name) missing from GPX") }
        files[index].contents = contents
    }

    /// Lays the filesystem out again (entry sector then data sectors, file by file)
    /// and compresses it.
    func serialized() throws -> Data {
        let size = Self.sectorSize
        var fs = Data(headerSector)
        for file in files {
            let dataSectors = (file.contents.count + size - 1) / size
            let firstData = fs.count / size + 1
            guard 0x94 + 4 * (dataSectors + 1) <= size else { throw TabError("\(file.name) is too large for GPX") }

            var entry = Data(file.entrySector)
            entry.replaceSubrange(0x8C ..< 0x90, with: Self.le32(file.contents.count))
            entry.replaceSubrange(0x94 ..< size, with: Data(count: size - 0x94))
            for i in 0..<dataSectors {
                entry.replaceSubrange(0x94 + 4 * i ..< 0x98 + 4 * i, with: Self.le32(firstData + i))
            }
            fs.append(entry)
            fs.append(file.contents)
            fs.append(Data(count: dataSectors * size - file.contents.count))
        }
        return BCFZ.compress(Data("BCFS".utf8) + fs)
    }

    private static func le32(_ value: Int) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }
}

/// The GP6 compression scheme. After the "BCFZ" magic and an int32 output
/// length, the bitstream (MSB first) is a sequence of chunks:
///   0, len:2 (LSB first), len raw bytes            — literals (len 0…3)
///   1, n:4, offset:n, size:n (both LSB first)      — copy `size` bytes from `offset` back
/// A copy never overlaps its source (the decoder copies min(offset, size) bytes).
enum BCFZ {
    static func decompress(_ data: Data) throws -> Data {
        let input = [UInt8](data)
        guard input.count >= 8 else { throw TabError("Truncated GPX file") }
        let expected = Data(input[4..<8]).uint32LE(at: 0)
        var reader = BitReader(bytes: input, position: 64)
        var out = [UInt8]()
        out.reserveCapacity(expected)
        while out.count < expected, !reader.atEnd {
            if reader.bits(1) == 1 {
                let width = reader.bits(4)
                let offset = reader.reversedBits(width)
                let size = reader.reversedBits(width)
                guard offset > 0, offset <= out.count else { throw TabError("Corrupt GPX compression") }
                let start = out.count - offset
                // Index loop rather than append(contentsOf: out[...]), which would copy the whole buffer.
                for k in start ..< start + min(offset, size) { out.append(out[k]) }
            } else {
                let count = reader.reversedBits(2)
                for _ in 0..<count { out.append(UInt8(reader.bits(8))) }
            }
        }
        // Some files in the wild end a little early; Guitar Pro tolerates that, so we do too
        // (missing sectors are caught when the filesystem is read).
        return Data(out.prefix(expected))
    }

    static func compress(_ data: Data) -> Data {
        let input = [UInt8](data)
        let n = input.count
        var writer = BitWriter()
        let maxDistance = (1 << 15) - 1
        let hashBits = 16
        var head = [Int](repeating: -1, count: 1 << hashBits)
        var prev = [Int](repeating: -1, count: n)

        func hash(_ i: Int) -> Int {
            let key = UInt32(input[i]) << 16 | UInt32(input[i + 1]) << 8 | UInt32(input[i + 2])
            return Int((key &* 2_654_435_761) >> (32 - UInt32(hashBits)))
        }
        func insert(_ i: Int) {
            guard i + 2 < n else { return }
            let h = hash(i)
            prev[i] = head[h]
            head[h] = i
        }

        var literals: [UInt8] = []
        func flushLiterals() {
            var index = 0
            while index < literals.count {
                let count = min(3, literals.count - index)
                writer.write(0, bits: 1)
                writer.writeReversed(count, bits: 2)
                for byte in literals[index ..< index + count] { writer.write(Int(byte), bits: 8) }
                index += count
            }
            literals.removeAll(keepingCapacity: true)
        }

        var i = 0
        while i < n {
            var bestLength = 0
            var bestOffset = 0
            if i + 2 < n {
                var candidate = head[hash(i)]
                var chain = 0
                while candidate >= 0, i - candidate <= maxDistance, chain < 48 {
                    let offset = i - candidate
                    let limit = min(offset, maxDistance, n - i)
                    var length = 0
                    while length < limit, input[candidate + length] == input[i + length] { length += 1 }
                    if length > bestLength {
                        bestLength = length
                        bestOffset = offset
                        if length == limit { break }
                    }
                    candidate = prev[candidate]
                    chain += 1
                }
            }

            let width = bitWidth(max(bestOffset, bestLength))
            if bestLength >= 3, bestLength * 9 > 5 + 2 * width {
                flushLiterals()
                writer.write(1, bits: 1)
                writer.write(width, bits: 4)
                writer.writeReversed(bestOffset, bits: width)
                writer.writeReversed(bestLength, bits: width)
                for j in i ..< i + bestLength { insert(j) }
                i += bestLength
            } else {
                literals.append(input[i])
                insert(i)
                i += 1
            }
        }
        flushLiterals()

        var out = Data("BCFZ".utf8)
        out.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24 & 0xFF)])
        out.append(contentsOf: writer.finish())
        return out
    }

    private static func bitWidth(_ value: Int) -> Int {
        value == 0 ? 1 : Int.bitWidth - value.leadingZeroBitCount
    }
}

struct BitReader {
    let bytes: [UInt8]
    var position: Int // in bits

    var atEnd: Bool { position >= bytes.count * 8 }

    mutating func bit() -> Int {
        guard !atEnd else { position += 1; return 0 }
        let value = Int(bytes[position >> 3] >> (7 - UInt8(position & 7))) & 1
        position += 1
        return value
    }

    mutating func bits(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count { value = value << 1 | bit() }
        return value
    }

    mutating func reversedBits(_ count: Int) -> Int {
        var value = 0
        for i in 0..<count { value |= bit() << i }
        return value
    }
}

struct BitWriter {
    private var bytes: [UInt8] = []
    private var current: UInt8 = 0
    private var used = 0

    mutating func bit(_ value: Int) {
        current |= UInt8(value & 1) << (7 - UInt8(used))
        used += 1
        if used == 8 {
            bytes.append(current)
            current = 0
            used = 0
        }
    }

    mutating func write(_ value: Int, bits count: Int) {
        for i in stride(from: count - 1, through: 0, by: -1) { bit(value >> i) }
    }

    mutating func writeReversed(_ value: Int, bits count: Int) {
        for i in 0..<count { bit(value >> i) }
    }

    mutating func finish() -> [UInt8] {
        if used > 0 { bytes.append(current) }
        return bytes
    }
}
