import Foundation

/// Moves tabs to `<root>/<artist>/<title>.<ext>` using slugged metadata, e.g.
/// "The Smashing Pumpkins" / "Thru The Eyes of Ruby" → the_smashing_pumpkins/thru_the_eyes_of_ruby.gp5
public enum Organizer {
    public struct Source: Sendable {
        public let url: URL
        public let artist: String
        public let title: String
        public init(url: URL, artist: String, title: String) {
            self.url = url
            self.artist = artist
            self.title = title
        }
    }

    public struct Move: Identifiable, Sendable {
        public let source: URL
        public let destination: URL
        public var id: URL { source }
    }

    public struct Skip: Identifiable, Sendable {
        public let source: URL
        public let reason: String
        public var id: URL { source }
        public init(source: URL, reason: String) {
            self.source = source
            self.reason = reason
        }
    }

    public struct Plan: Sendable {
        public let root: URL
        public var moves: [Move] = []
        public var skipped: [Skip] = []
        public var alreadyInPlace = 0
    }

    public struct Result: Sendable {
        public var moved: [Move] = []
        public var failures: [(source: URL, error: String)] = []
        public var removedFolders = 0
    }

    public static func slug(_ text: String) -> String {
        var slug = text
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "['’‘`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if slug.count > 100 { slug = String(slug.prefix(100)).trimmingCharacters(in: CharacterSet(charactersIn: "_")) }
        return slug
    }

    /// Works out every move without touching the disk (other than checking what exists).
    /// Never targets an occupied path; clashes get a `_2`, `_3`… suffix.
    public static func plan(_ sources: [Source], root: URL) -> Plan {
        // Resolve symlinks (e.g. /tmp → /private/tmp) so root and source paths compare reliably.
        let root = root.resolvingSymlinksInPath()
        let sources = sources.map { Source(url: $0.url.resolvingSymlinksInPath(), artist: $0.artist, title: $0.title) }
        var plan = Plan(root: root)
        var claimed = Set<String>() // lowercased paths, since APFS is usually case-insensitive

        var candidates: [(source: Source, folder: String, name: String, ext: String)] = []
        for source in sources.sorted(by: { $0.url.path < $1.url.path }) {
            let folder = slug(source.artist), name = slug(source.title)
            if source.artist.trimmingCharacters(in: .whitespaces).isEmpty || source.title.trimmingCharacters(in: .whitespaces).isEmpty {
                plan.skipped.append(Skip(source: source.url, reason: "Missing artist or title"))
            } else if folder.isEmpty || name.isEmpty {
                plan.skipped.append(Skip(source: source.url, reason: "Artist or title has no usable characters for a file name"))
            } else {
                candidates.append((source, folder, name, source.url.pathExtension.lowercased()))
            }
        }

        func destination(_ folder: String, _ name: String, _ ext: String, _ n: Int) -> URL {
            root.appending(path: folder, directoryHint: .isDirectory)
                .appending(path: (n == 1 ? name : "\(name)_\(n)") + "." + ext)
        }

        // Files already in the right place (including an earlier "_2" duplicate) keep it,
        // so organizing twice changes nothing and newcomers can't bump them.
        var remaining: [(Source, String, String, String)] = []
        for (source, folder, name, ext) in candidates {
            let inFolder = source.url.deletingLastPathComponent().path == destination(folder, name, ext, 1).deletingLastPathComponent().path
            let file = source.url.lastPathComponent
            let suffix = file.hasPrefix(name + "_") && file.hasSuffix("." + ext)
                ? Int(file.dropFirst(name.count + 1).dropLast(ext.count + 1)) : nil
            if inFolder && (file == name + "." + ext || (suffix ?? 0) >= 2) {
                claimed.insert(source.url.path.lowercased())
                plan.alreadyInPlace += 1
            } else {
                remaining.append((source, folder, name, ext))
            }
        }

        for (source, folder, name, ext) in remaining {
            let sourcePath = source.url.path
            var n = 1
            var target = destination(folder, name, ext, n)
            while claimed.contains(target.path.lowercased())
                || (FileManager.default.fileExists(atPath: target.path) && target.path.lowercased() != sourcePath.lowercased())
            {
                n += 1
                target = destination(folder, name, ext, n)
            }
            claimed.insert(target.path.lowercased())
            plan.moves.append(Move(source: source.url, destination: target))
        }
        return plan
    }

    public static func execute(_ plan: Plan) -> Result {
        let fm = FileManager.default
        var result = Result()

        for move in plan.moves {
            do {
                try fm.createDirectory(at: move.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if move.source.path.lowercased() == move.destination.path.lowercased() {
                    try renameChangingCase(move.source, to: move.destination)
                } else {
                    try fm.moveItem(at: move.source, to: move.destination) // fails rather than overwrite
                }
                result.moved.append(move)
            } catch {
                result.failures.append((move.source, error.localizedDescription))
            }
        }

        // On a case-insensitive disk a file can land in an existing "Smashing_Pumpkins" folder;
        // fix folder casing only now, once no pending source paths can be affected.
        let folders = Set(result.moved.map { $0.destination.deletingLastPathComponent() })
        for folder in folders {
            if let actual = try? fm.contentsOfDirectory(atPath: plan.root.path)
                .first(where: { $0.lowercased() == folder.lastPathComponent.lowercased() }),
                actual != folder.lastPathComponent
            {
                try? renameChangingCase(plan.root.appending(path: actual), to: folder)
            }
        }

        // Remove folders the moves left empty (ignoring Finder's .DS_Store), up to the root.
        var emptied = Set(result.moved.map { $0.source.deletingLastPathComponent() })
        while let folder = emptied.popFirst() {
            guard folder.path.hasPrefix(plan.root.path + "/"),
                  let contents = try? fm.contentsOfDirectory(atPath: folder.path),
                  contents.allSatisfy({ $0 == ".DS_Store" })
            else { continue }
            if (try? fm.removeItem(at: folder)) != nil {
                result.removedFolders += 1
                emptied.insert(folder.deletingLastPathComponent())
            }
        }
        return result
    }

    /// Case-only renames need a hop through a temporary name on case-insensitive volumes.
    private static func renameChangingCase(_ source: URL, to destination: URL) throws {
        let temporary = source.deletingLastPathComponent().appending(path: ".tabmanager-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: source, to: temporary)
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            try? FileManager.default.moveItem(at: temporary, to: source)
            throw error
        }
    }
}
