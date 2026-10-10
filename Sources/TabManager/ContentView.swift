import SwiftUI
import TabCore

struct ContentView: View {
    @Environment(Library.self) private var library

    var body: some View {
        @Bindable var library = library
        Group {
            if library.root == nil, !library.isLoading {
                ContentUnavailableView {
                    Label("No Folder Open", systemImage: "folder")
                } description: {
                    Text(library.statusMessage ?? "Choose the folder that holds your Guitar Pro files. It will open automatically next time; you can change that in Settings.")
                } actions: {
                    Button("Open Folder…") { library.chooseFolder() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                HSplitView {
                    table
                        .frame(minWidth: 500)
                    InspectorView()
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
                }
            }
        }
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "Search title, artist, file…")
        .toolbar {
            ToolbarItemGroup {
                Button("Choose Folder…", systemImage: "folder") { library.chooseFolder() }
                Button("Reload", systemImage: "arrow.clockwise") { library.reload() }
                    .disabled(library.root == nil || library.isLoading)
                Button {
                    Task { await library.saveAll() }
                } label: {
                    Label("Save \(library.dirtyItems.count) Changed", systemImage: "square.and.arrow.down")
                }
                .disabled(library.dirtyItems.isEmpty || library.isSaving)
                .help("Write all staged edits to disk (⌘S)")
            }
        }
        .navigationTitle(library.root?.lastPathComponent ?? "Tab Manager")
        .navigationSubtitle(subtitle)
        .overlay {
            if library.isLoading { ProgressView("Reading tabs…") }
        }
    }

    private var subtitle: String {
        let visible = library.visibleItems.count
        var parts = [library.statusMessage ?? ""]
        if !library.searchText.isEmpty { parts.append("\(visible) shown") }
        if !library.selection.isEmpty { parts.append("\(library.selection.count) selected") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var table: some View {
        @Bindable var library = library
        return Table(library.visibleItems, selection: $library.selection, sortOrder: $library.sortOrder) {
            TableColumn("") { (item: TabItem) in
                if item.isDirty {
                    Image(systemName: "circle.fill").foregroundStyle(.orange).imageScale(.small).help("Unsaved changes")
                } else if !item.isEditable {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).imageScale(.small).help(item.error ?? "Read-only")
                }
            }
            .width(16)
            TableColumn("Title", value: \.sortTitle) { item in cell(item, .title) }
            TableColumn("Artist", value: \.sortArtist) { item in cell(item, .artist) }
            TableColumn("Album", value: \.sortAlbum) { item in cell(item, .album) }
            TableColumn("Tab Author", value: \.sortTabber) { item in cell(item, .tabber) }
                .defaultVisibility(.hidden)
            TableColumn("Format", value: \.sortFormat) { item in Text(item.format.rawValue).foregroundStyle(.secondary) }
                .width(min: 40, ideal: 48, max: 70)
            TableColumn("File", value: \.relativePath) { item in
                Text(item.relativePath).foregroundStyle(.secondary).help(item.relativePath)
            }
        }
        .contextMenu(forSelectionType: TabItem.ID.self) { _ in
            Button("Open in Guitar Pro") { library.openSelected() }
            Button("Show in Finder") { library.revealInFinder() }
            Divider()
            Button("Fill Empty Artist/Title from Filename") { library.fillFromFilename(.emptyOnly) }
            Button("Overwrite Artist/Title from Filename") { library.fillFromFilename(.overwrite) }
            Divider()
            Button("Revert Changes") { library.revertSelected() }
        } primaryAction: { _ in
            library.openSelected()
        }
    }

    private func cell(_ item: TabItem, _ field: Field) -> some View {
        let changed = item.pending[field] != item.saved[field]
        return Text(item.pending[field])
            .foregroundStyle(changed ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
            .help(changed ? "Was: \(item.saved[field].isEmpty ? "(empty)" : item.saved[field])" : "")
    }
}
