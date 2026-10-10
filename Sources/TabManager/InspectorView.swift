import SwiftUI
import TabCore

/// Edits the fields of every selected file at once. A field whose value differs
/// across the selection shows "Multiple values"; typing into it sets all of them.
struct InspectorView: View {
    /// Fields that offer completions from values already used in the library.
    private static let suggestedFields: Set<Field> = [.artist]

    @Environment(Library.self) private var library

    var body: some View {
        let items = library.selectedItems
        Group {
            if items.isEmpty {
                ContentUnavailableView("No Selection", systemImage: "music.note.list",
                                       description: Text("Select one or more tabs to edit their details. ⌘A selects everything shown."))
            } else {
                editor(items)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func editor(_ items: [TabItem]) -> some View {
        let editable = items.filter(\.isEditable)
        return Form {
            Section {
                header(items, editable: editable)
            }
            if !editable.isEmpty {
                Section {
                    ForEach(Field.allCases) { field in
                        fieldRow(field, items: editable)
                    }
                }
                Section {
                    HStack {
                        Menu("Fill from Filename") {
                            Button("Only Empty Artist/Title") { library.fillFromFilename(.emptyOnly) }
                            Button("Overwrite Artist/Title") { library.fillFromFilename(.overwrite) }
                        }
                        .fixedSize()
                        Spacer()
                        Button("Revert") { library.revertSelected() }
                            .disabled(!items.contains(where: \.isDirty))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func header(_ items: [TabItem], editable: [TabItem]) -> some View {
        if items.count == 1, let item = items.first {
            LabeledContent("File", value: item.fileName)
            LabeledContent("Format", value: item.format.rawValue)
            if let error = item.error {
                Label(error, systemImage: "lock.fill").foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Editing", value: "\(editable.count) files")
            if editable.count < items.count {
                Label("\(items.count - editable.count) read-only file(s) will be skipped", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func fieldRow(_ field: Field, items: [TabItem]) -> some View {
        let applicable = items.filter { $0.supports(field) }
        let values = Set(applicable.map { $0.pending[field] })
        let mixed = values.count > 1
        let binding = Binding<String>(
            get: { mixed ? "" : values.first ?? "" },
            set: { library.set(field, to: $0) }
        )
        let changed = applicable.contains { $0.pending[field] != $0.saved[field] }
        let suggestions = Self.suggestedFields.contains(field) ? library.suggestions(for: field, matching: binding.wrappedValue) : []

        TextField(text: binding, prompt: Text(mixed ? "Multiple values" : ""), axis: field == .notices || field == .instructions ? .vertical : .horizontal) {
            HStack(spacing: 4) {
                Text(field.label)
                if changed { Circle().fill(.orange).frame(width: 6, height: 6) }
            }
        }
        .lineLimit(field == .notices ? 2...6 : 1...4)
        .textInputSuggestions(suggestions) { suggestion in
            HStack {
                Text(suggestion.value)
                Spacer()
                Text("\(suggestion.count) tab\(suggestion.count == 1 ? "" : "s")").foregroundStyle(.secondary)
            }
            .textInputCompletion(suggestion.value)
        }
        .disabled(applicable.isEmpty)
        .help(applicable.isEmpty ? "\(field.label) isn't stored in \(Set(items.map(\.format.rawValue)).sorted().joined(separator: "/")) files"
              : applicable.count < items.count ? "Only \(applicable.count) of the selected files can store \(field.label)" : "")
    }
}
