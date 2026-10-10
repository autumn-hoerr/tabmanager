import SwiftUI
import TabCore

/// Previews an organize run and asks for confirmation; nothing moves until "Move" is clicked.
struct OrganizeSheet: View {
    @Environment(Library.self) private var library
    let plan: Organizer.Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(plan.moves.isEmpty ? "Nothing to Organize" : "Organize \(plan.moves.count) File\(plan.moves.count == 1 ? "" : "s")?")
                .font(.title2.bold())
            Text("Each file will be moved into a folder named after its artist and renamed after its song title, inside “\(plan.root.lastPathComponent)”. Folders left empty are removed.")
                .fixedSize(horizontal: false, vertical: true)

            if plan.moves.isEmpty {
                Text(plan.alreadyInPlace > 0 ? "All \(plan.alreadyInPlace) files are already where they belong." : "None of these files have both an artist and a title.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(plan.moves) {
                    TableColumn("Current Location") { move in path(move.source) }
                    TableColumn("New Location") { move in path(move.destination) }
                }
                .frame(minHeight: 240)
            }

            if !plan.skipped.isEmpty {
                DisclosureGroup("\(plan.skipped.count) file\(plan.skipped.count == 1 ? "" : "s") will be left where they are") {
                    List(plan.skipped) { skip in
                        HStack {
                            path(skip.source)
                            Spacer()
                            Text(skip.reason).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(height: 120)
                }
            }
            if plan.alreadyInPlace > 0, !plan.moves.isEmpty {
                Text("\(plan.alreadyInPlace) file\(plan.alreadyInPlace == 1 ? " is" : "s are") already in the right place.")
                    .foregroundStyle(.secondary)
            }

            if !plan.moves.isEmpty {
                Label {
                    Text("**This can't be undone.** Files are moved and renamed on disk, and Tab Manager can't put them back. A list of every move is saved to Organize Logs for reference.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { library.organizePlan = nil }
                    .keyboardShortcut(.cancelAction)
                if !plan.moves.isEmpty {
                    Button("Move \(plan.moves.count) File\(plan.moves.count == 1 ? "" : "s")", role: .destructive) {
                        Task { await library.performOrganize() }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 820, height: plan.moves.isEmpty ? 300 : 620)
    }

    private func path(_ url: URL) -> some View {
        let relative = url.path.replacingOccurrences(of: plan.root.path + "/", with: "")
        return Text(relative).lineLimit(1).truncationMode(.middle).help(relative)
    }
}
