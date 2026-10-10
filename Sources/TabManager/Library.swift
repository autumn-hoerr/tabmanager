import AppKit
import Foundation
import Observation
import TabCore

@Observable
final class TabItem: Identifiable {
    let url: URL
    let relativePath: String
    let format: TabFormat
    /// What's on disk.
    var saved: TabMetadata
    /// Edits staged in the UI; written on Save.
    var pending: TabMetadata
    var error: String?

    var id: URL { url }
    var fileName: String { url.lastPathComponent }
    var folder: String { (relativePath as NSString).deletingLastPathComponent }
    var isEditable: Bool { error == nil && format != .unsupported }
    var isDirty: Bool { pending != saved }

    // Sort keys use saved values so rows don't jump around while you type.
    var sortTitle: String { saved[.title] }
    var sortArtist: String { saved[.artist] }
    var sortAlbum: String { saved[.album] }
    var sortTabber: String { saved[.tabber] }
    var sortFormat: String { format.rawValue }

    init(url: URL, relativePath: String, format: TabFormat, metadata: TabMetadata, error: String?) {
        self.url = url
        self.relativePath = relativePath
        self.format = format
        self.saved = metadata
        self.pending = metadata
        self.error = error
    }

    func supports(_ field: Field) -> Bool { isEditable && format.supportedFields.contains(field) }
}

@Observable
@MainActor
final class Library {
    private static let defaultFolderKey = "DefaultFolder"

    var root: URL?
    var items: [TabItem] = []
    var isLoading = false
    var isSaving = false
    var searchText = ""
    var sortOrder = [KeyPathComparator(\TabItem.sortArtist), KeyPathComparator(\TabItem.sortTitle)]
    var selection = Set<TabItem.ID>()
    var statusMessage: String?

    /// Opened at launch. Set automatically the first time a folder is opened; editable in Settings.
    var defaultFolder: URL? {
        didSet { UserDefaults.standard.set(defaultFolder?.path, forKey: Self.defaultFolderKey) }
    }

    init() {
        UserDefaults.standard.removeObject(forKey: "LibraryRoot") // replaced by DefaultFolder
        defaultFolder = UserDefaults.standard.string(forKey: Self.defaultFolderKey).map { URL(fileURLWithPath: $0) }
        if let defaultFolder {
            if FileManager.default.fileExists(atPath: defaultFolder.path) {
                Task { await load(defaultFolder) }
            } else {
                statusMessage = "Default folder \(defaultFolder.path) not found"
            }
        }
    }

    var visibleItems: [TabItem] {
        let terms = searchText.lowercased().split(separator: " ").map(String.init)
        let filtered = terms.isEmpty ? items : items.filter { item in
            let haystack = ([item.relativePath] + Field.allCases.map { item.saved[$0] }).joined(separator: "\n").lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
        return filtered.sorted(using: sortOrder)
    }

    var selectedItems: [TabItem] { items.filter { selection.contains($0.id) } }
    var dirtyItems: [TabItem] { items.filter(\.isDirty) }

    func chooseFolder() {
        guard let url = Self.pickFolder(startingAt: root, prompt: "Open") else { return }
        Task { await load(url) }
    }

    func chooseDefaultFolder() {
        guard let url = Self.pickFolder(startingAt: defaultFolder ?? root, prompt: "Set as Default") else { return }
        defaultFolder = url
    }

    private static func pickFolder(startingAt directory: URL?, prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = prompt
        panel.directoryURL = directory
        return panel.runModal() == .OK ? panel.url : nil
    }

    func reload() {
        guard let root else { return }
        Task { await load(root) }
    }

    func load(_ folder: URL) async {
        if !dirtyItems.isEmpty, !confirmDiscard() { return }
        root = folder
        if defaultFolder == nil { defaultFolder = folder }
        isLoading = true
        selection = []
        items = await Task.detached(priority: .userInitiated) { Self.scan(folder) }.value
        isLoading = false
        let problems = items.filter { !$0.isEditable }.count
        statusMessage = "\(items.count) files" + (problems > 0 ? " · \(problems) read-only" : "")
    }

    nonisolated private static func scan(_ folder: URL) -> [TabItem] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        let urls = (enumerator?.allObjects as? [URL] ?? [])
            .filter { TabFormat.fileExtensions.contains($0.pathExtension.lowercased()) }
        let base = folder.standardizedFileURL.path + "/"
        return urls.map { url in
            let relative = url.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
            do {
                let data = try Data(contentsOf: url)
                let (format, metadata) = try TabFile.read(data)
                return TabItem(url: url, relativePath: relative, format: format, metadata: metadata, error: nil)
            } catch {
                let format = (try? Data(contentsOf: url)).map(TabFormat.detect) ?? .unsupported
                return TabItem(url: url, relativePath: relative, format: format, metadata: TabMetadata(), error: error.localizedDescription)
            }
        }
    }

    // MARK: Editing

    /// Sets a field on every selected file that can hold it.
    func set(_ field: Field, to value: String) {
        for item in selectedItems where item.supports(field) {
            item.pending[field] = value
        }
    }

    enum FilenameFill { case emptyOnly, overwrite }

    /// Guesses artist and title from names like "Artist - Title.gp5", "Artist-Title-09-06-2026.gp",
    /// or "song_title_2.gp4" inside an artist folder.
    func fillFromFilename(_ mode: FilenameFill) {
        for item in selectedItems where item.isEditable {
            let topFolder = item.folder.split(separator: "/").first.map(String.init)
            let guess = Self.parseFilename(item.url.deletingPathExtension().lastPathComponent, folder: topFolder)
            for (field, value) in [(Field.artist, guess.artist), (.title, guess.title)] {
                guard let value, !value.isEmpty else { continue }
                if mode == .overwrite || item.pending[field].trimmingCharacters(in: .whitespaces).isEmpty {
                    item.pending[field] = value
                }
            }
        }
    }

    nonisolated static func parseFilename(_ name: String, folder: String?) -> (artist: String?, title: String?) {
        var stem = name
            .replacingOccurrences(of: #"-\d{2}-\d{2}-\d{4}$"#, with: "", options: .regularExpression) // "-09-06-2026"
            .replacingOccurrences(of: #"_\d+$"#, with: "", options: .regularExpression) // UG version suffix "_4"
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if stem == stem.lowercased() { stem = stem.capitalized }

        for separator in [" - ", " – ", "-"] {
            if let range = stem.range(of: separator) {
                let artist = stem[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
                let title = stem[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty, !title.isEmpty { return (artist, title) }
            }
        }
        return (folder, stem)
    }

    // MARK: Suggestions

    struct Suggestion: Identifiable {
        let value: String
        let count: Int
        var id: String { value }
    }

    /// Existing values of `field` that contain `text`, from saved files and other files' staged edits.
    /// Selected files count by their saved value, since their staged value is what's being typed.
    func suggestions(for field: Field, matching text: String, limit: Int = 8) -> [Suggestion] {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        for item in items where item.isEditable {
            let value = selection.contains(item.id) ? item.saved[field] : item.pending[field]
            if !value.isEmpty { counts[value, default: 0] += 1 }
        }

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func rank(_ value: String) -> Int? {
            guard let range = value.range(of: query, options: options) else { return nil }
            if range.lowerBound == value.startIndex { return 0 }
            return value[value.index(before: range.lowerBound)].isLetter ? 2 : 1 // word start beats mid-word
        }

        return counts
            .filter { $0.key != text }
            .compactMap { value, count in rank(value).map { (rank: $0, suggestion: Suggestion(value: value, count: count)) } }
            .sorted { a, b in
                if a.rank != b.rank { return a.rank < b.rank }
                if a.suggestion.count != b.suggestion.count { return a.suggestion.count > b.suggestion.count }
                return a.suggestion.value.localizedStandardCompare(b.suggestion.value) == .orderedAscending
            }
            .prefix(limit)
            .map(\.suggestion)
    }

    func revertSelected() {
        for item in selectedItems { item.pending = item.saved }
    }

    func revertAll() {
        for item in items { item.pending = item.saved }
    }

    // MARK: Saving

    func saveAll() async {
        let dirty = dirtyItems
        guard !dirty.isEmpty, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let backupRoot = URL.applicationSupportDirectory.appending(path: "TabManager/Backups/\(stamp)")
        let jobs = dirty.map { (url: $0.url, relativePath: $0.relativePath, changes: $0.pending.changes(from: $0.saved)) }

        let results = await Task.detached(priority: .userInitiated) {
            jobs.map { job in Result { try Self.write(job.changes, to: job.url, backup: backupRoot.appending(path: job.relativePath)) } }
        }.value

        var failures: [String] = []
        for (item, result) in zip(dirty, results) {
            switch result {
            case .success(let metadata):
                item.saved = metadata
                item.pending = metadata
            case .failure(let error):
                failures.append("\(item.fileName): \(error.localizedDescription)")
            }
        }
        let saved = dirty.count - failures.count
        statusMessage = "Saved \(saved) file\(saved == 1 ? "" : "s")" + (failures.isEmpty ? "" : " · \(failures.count) failed")
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some files couldn't be saved"
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
    }

    /// Reads the file fresh, applies only the changed fields, backs up the
    /// original, then atomically replaces it.
    nonisolated private static func write(_ changes: [Field: String], to url: URL, backup: URL) throws -> TabMetadata {
        let original = try Data(contentsOf: url)
        let updated = try TabFile.apply(changes, to: original)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: backup)
        try updated.write(to: url, options: .atomic)
        return try TabFile.read(updated).1
    }

    func confirmDiscard() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes to \(dirtyItems.count) file(s)?"
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(selectedItems.map(\.url))
    }

    func openSelected() {
        for item in selectedItems { NSWorkspace.shared.open(item.url) }
    }

    func openBackups() {
        let url = URL.applicationSupportDirectory.appending(path: "TabManager/Backups")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
}
