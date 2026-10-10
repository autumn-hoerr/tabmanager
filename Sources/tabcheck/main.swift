import Foundation
import TabCore

// Developer tool: reads every tab under a folder and round-trips metadata edits
// in memory. Never writes to the input files.
//   tabcheck <folder>            read everything, report failures
//   tabcheck <folder> --edit     also apply edits, verify, and revert each file in memory

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: tabcheck <folder> [--edit] [--show] [--verbose]")
    exit(2)
}
let root = URL(fileURLWithPath: args[1])
let edit = args.contains("--edit")
let show = args.contains("--show")
let verbose = args.contains("--verbose")

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
