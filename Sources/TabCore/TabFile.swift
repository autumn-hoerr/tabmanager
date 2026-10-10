import Foundation

public enum TabFormat: String, Sendable {
    case gp3 = "GP3", gp4 = "GP4", gp5 = "GP5", gpx = "GP6", gp = "GP7+", unsupported = "—"

    public static let fileExtensions: Set<String> = ["gp3", "gp4", "gp5", "gpx", "gp", "gtp"]

    public var supportedFields: Set<Field> {
        switch self {
        case .gp3: LegacyFormat.supportedFields(version: 3)
        case .gp4: LegacyFormat.supportedFields(version: 4)
        case .gp5: LegacyFormat.supportedFields(version: 5)
        case .gpx, .gp: Set(Field.allCases)
        case .unsupported: []
        }
    }

    /// Detected from the file contents, not the extension.
    public static func detect(_ data: Data) -> TabFormat {
        switch LegacyFormat.version(of: data) {
        case 3: return .gp3
        case 4: return .gp4
        case 5: return .gp5
        default: break
        }
        let magic = data.prefix(4)
        if magic == Data("BCFZ".utf8) || magic == Data("BCFS".utf8) { return .gpx }
        if magic == Data([0x50, 0x4B, 0x03, 0x04]) { return .gp }
        return .unsupported
    }
}

public enum TabFile {
    public static func read(_ data: Data) throws -> (TabFormat, TabMetadata) {
        let format = TabFormat.detect(data)
        switch format {
        case .gp3, .gp4, .gp5:
            return (format, try LegacyFormat.read(data))
        case .gpx:
            return (format, try GPIF.read(GPXArchive(data).contents(of: "score.gpif")))
        case .gp:
            let archive = try ZipArchive(data)
            if archive.entries.contains(where: { $0.name == "editLocked" }) {
                throw TabError("Locked by its publisher (the score is encrypted), so it can't be edited")
            }
            return (format, try GPIF.read(archive.contents(of: "Content/score.gpif")))
        case .unsupported:
            throw TabError("This Guitar Pro version isn't supported")
        }
    }

    /// Returns new file contents with `changes` applied. The result is re-read
    /// and checked before it is returned, so a bad write never reaches disk.
    public static func apply(_ changes: [Field: String], to data: Data) throws -> Data {
        let (format, before) = try read(data)
        let changes = changes.filter { format.supportedFields.contains($0.key) }
        guard !changes.isEmpty else { return data }

        let output: Data
        switch format {
        case .gp3, .gp4, .gp5:
            output = try LegacyFormat.apply(changes, to: data)
        case .gpx:
            var archive = try GPXArchive(data)
            try archive.replace("score.gpif", with: GPIF.apply(changes, to: archive.contents(of: "score.gpif")))
            output = try archive.serialized()
        case .gp:
            var archive = try ZipArchive(data)
            try archive.replace("Content/score.gpif", with: GPIF.apply(changes, to: archive.contents(of: "Content/score.gpif")))
            output = archive.serialized()
        case .unsupported:
            throw TabError("This Guitar Pro version isn't supported")
        }

        try verify(original: data, before: before, output: output, format: format, changes: changes)
        return output
    }

    /// What a GP3–5 file can actually hold: Windows-1252, 255 bytes per line.
    private static func storedLegacyValue(_ value: String, field: Field) -> String {
        let lines = field == .notices ? (value.isEmpty ? [] : value.components(separatedBy: "\n")) : [value]
        return lines.map { LegacyFormat.decode(LegacyFormat.encode($0)) }.joined(separator: "\n")
    }

    private static func verify(original: Data, before: TabMetadata, output: Data, format: TabFormat, changes: [Field: String]) throws {
        let (newFormat, after) = try read(output)
        guard newFormat == format else { throw TabError("Verification failed: format changed") }

        // Untouched fields must be exactly as they were.
        for field in format.supportedFields where changes[field] == nil && after[field] != before[field] {
            throw TabError("Verification failed: \(field.label) changed unexpectedly")
        }
        // Edited fields must read back as written (allowing for Windows-1252 / 255-byte limits in GP3–5).
        for (field, value) in changes {
            let expected = [.gp, .gpx].contains(format) ? value : storedLegacyValue(value, field: field)
            guard after[field] == expected else { throw TabError("Verification failed: \(field.label) didn't save correctly") }
        }

        // Everything other than the metadata must survive unchanged.
        switch format {
        case .gp3, .gp4, .gp5:
            let old = try LegacyFormat.parseHeader(original), new = try LegacyFormat.parseHeader(output)
            guard original[(original.startIndex + old.end)...] == output[(output.startIndex + new.end)...] else {
                throw TabError("Verification failed: song data changed")
            }
        case .gpx:
            let old = try GPXArchive(original), new = try GPXArchive(output)
            guard old.files.map(\.name) == new.files.map(\.name),
                  zip(old.files, new.files).allSatisfy({ $0.name == "score.gpif" || $0.contents == $1.contents })
            else { throw TabError("Verification failed: GPX contents changed") }
        case .gp:
            let old = try ZipArchive(original), new = try ZipArchive(output)
            guard old.entries.map(\.name) == new.entries.map(\.name),
                  try zip(old.entries, new.entries).allSatisfy({ o, n in
                      try o.name == "Content/score.gpif" || old.contents(of: o.name) == new.contents(of: n.name)
                  })
            else { throw TabError("Verification failed: archive contents changed") }
        case .unsupported:
            break
        }
    }
}
