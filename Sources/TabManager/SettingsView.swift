import SwiftUI

struct SettingsView: View {
    @Environment(Library.self) private var library

    var body: some View {
        Form {
            LabeledContent("Open at launch") {
                VStack(alignment: .leading, spacing: 8) {
                    if let folder = library.defaultFolder {
                        Label(folder.path(percentEncoded: false), systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder.path(percentEncoded: false))
                    } else {
                        Text("Nothing — start with no folder open").foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Choose…") { library.chooseDefaultFolder() }
                        Button("Use Current Folder") { library.defaultFolder = library.root }
                            .disabled(library.root == nil || library.root == library.defaultFolder)
                        Button("Clear") { library.defaultFolder = nil }
                            .disabled(library.defaultFolder == nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
