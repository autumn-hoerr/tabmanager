import Foundation
import TabCore

// Developer tool: reads every tab under a folder and round-trips metadata edits
// in memory. Never writes to the input files.
//   tabcheck <folder>            read everything, report failures
//   tabcheck <folder> --edit     also apply edits, verify, and revert each file in memory
//   tabcheck <folder> --organize MOVES FILES: reorganizes by metadata, then verifies nothing was lost.
//                                Only point this at a scratch copy.

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: tabcheck <folder> [--edit] [--show] [--verbose] [--organize]")
    exit(2)
}
let root = URL(fileURLWithPath: args[1])
let edit = args.contains("--edit")
let show = args.contains("--show")
let verbose = args.contains("--verbose")

func tabFiles(_ root: URL) -> [URL] {
    FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        .compactMap { $0 as? URL }
        .filter { TabFormat.fileExtensions.contains($0.pathExtension.lowercased()) }
}

if args.contains("--organize") {
    let before = tabFiles(root)
    var sources: [Organizer.Source] = []
    var checksums: [String: Data] = [:]
    for url in before {
        let data = try! Data(contentsOf: url)
        if let (_, meta) = try? TabFile.read(data) {
            sources.append(Organizer.Source(url: url, artist: meta[.artist], title: meta[.title]))
        }
        checksums[url.resolvingSymlinksInPath().path] = data
    }
    let plan = Organizer.plan(sources, root: root)
    for move in plan.moves.prefix(15) {
        print("\(move.source.path.replacingOccurrences(of: plan.root.path, with: ""))  →  \(move.destination.path.replacingOccurrences(of: plan.root.path, with: ""))")
    }
    print("planned \(plan.moves.count) moves, \(plan.skipped.count) skipped, \(plan.alreadyInPlace) in place")
    let result = Organizer.execute(plan)
    print("moved \(result.moved.count), failed \(result.failures.count), removed \(result.removedFolders) empty folders")
    for failure in result.failures { print("FAIL \(failure.source.path): \(failure.error)") }

    // Every original file's bytes must exist exactly once afterwards.
    let after = tabFiles(root)
    var problems = before.count == after.count ? 0 : 1
    if problems > 0 { print("FAIL file count \(before.count) → \(after.count)") }
    for move in result.moved where try! Data(contentsOf: move.destination) != checksums[move.source.path] {
        problems += 1
        print("FAIL contents differ at \(move.destination.path)")
    }
    // Running again should find nothing left to do.
    let again = Organizer.plan(after.compactMap { url in
        (try? TabFile.read(Data(contentsOf: url))).map { Organizer.Source(url: url, artist: $0.1[.artist], title: $0.1[.title]) }
    }, root: root)
    print("second pass: \(again.moves.count) moves")
    if again.moves.count > 0 { problems += 1 }
    exit(problems == 0 && result.failures.isEmpty ? 0 : 1)
}

let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
    .compactMap { $0 as? URL }
    .filter { TabFormat.fileExtensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.path < $1.path }

var counts: [String: Int] = [:]
var failures = 0
let started = Date()
for url in files {
    let name = url.path.replacingOccurrences(of: root.path + "/", with: "")
    let fileStart = Date()
    do {
        let data = try Data(contentsOf: url)
        let (format, meta) = try TabFile.read(data)
        counts[format.rawValue, default: 0] += 1
        if show { print("\(format.rawValue)\t\(name)\t\(meta[.artist])\t\(meta[.title])\t\(meta[.album])") }
        guard edit else { continue }

        let edited = try TabFile.apply([.title: "Tëst “Title” ]]> & <x>", .artist: "Ärtist", .notices: "line one\nline two"], to: data)
        let (_, editedMeta) = try TabFile.read(edited)
        guard editedMeta[.artist] == "Ärtist" else { throw TabError("artist not saved") }

        let restored = try TabFile.apply(meta.changes(from: editedMeta), to: edited)
        let (_, restoredMeta) = try TabFile.read(restored)
        guard restoredMeta == meta else { throw TabError("restore mismatch") }

        // Title/artist edits on GP3–5 must restore to the exact original bytes.
        if [.gp3, .gp4, .gp5].contains(format) {
            let renamed = try TabFile.apply([.title: "x", .artist: "y"], to: data)
            let (_, renamedMeta) = try TabFile.read(renamed)
            guard try TabFile.apply(meta.changes(from: renamedMeta), to: renamed) == data else {
                throw TabError("restored bytes differ")
            }
        }
        if verbose { print("\(format.rawValue)\t\(data.count)\t\(edited.count)\t\(String(format: "%.2f", Date().timeIntervalSince(fileStart)))s\t\(name)") }
    } catch {
        failures += 1
        print("FAIL \(name): \(error.localizedDescription)")
    }
}
print(counts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
print("\(files.count) files, \(failures) failures, \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
exit(failures == 0 ? 0 : 1)
