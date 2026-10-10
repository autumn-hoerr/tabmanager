import Foundation

/// The song-information fields Guitar Pro stores in every file format.
public enum Field: String, CaseIterable, Identifiable, Sendable {
    case title, subtitle, artist, album, words, music, copyright, tabber, instructions, notices

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .title: "Title"
        case .subtitle: "Subtitle"
        case .artist: "Artist"
        case .album: "Album"
        case .words: "Words"
        case .music: "Music"
        case .copyright: "Copyright"
        case .tabber: "Tab Author"
        case .instructions: "Instructions"
        case .notices: "Notices"
        }
    }
}

public struct TabMetadata: Equatable, Hashable, Sendable {
    public var values: [Field: String] = [:]

    public init(_ values: [Field: String] = [:]) {
        self.values = values
    }

    public subscript(field: Field) -> String {
        get { values[field] ?? "" }
        set { values[field] = newValue }
    }

    /// Fields whose value differs from `other`.
    public func changes(from other: TabMetadata) -> [Field: String] {
        var result: [Field: String] = [:]
        for field in Field.allCases where self[field] != other[field] {
            result[field] = self[field]
        }
        return result
    }

    public static func == (lhs: TabMetadata, rhs: TabMetadata) -> Bool {
        Field.allCases.allSatisfy { lhs[$0] == rhs[$0] }
    }

    public func hash(into hasher: inout Hasher) {
        for field in Field.allCases { hasher.combine(self[field]) }
    }
}

public struct TabError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
