import SwiftUI

struct FoldersView: View {
    @EnvironmentObject var store: NotebookStore
    
    @State private var showNewFolder = false
    @State private var newFolderName = "New Folder"
    
    @State private var renamingFolder: Folder? = nil
    @State private var renameText = ""
    @State private var renamingNote: NotebookMeta?
    @State private var noteToDelete: NotebookMeta?
    @State private var showDeleteAlert = false
    
    var body: some View {
        NavigationStack {
            List {
                ZStack{
                    ForEach(store.folders) { folder in
                        NavigationLink(folder.name) {
                            NotebooksView(folder: folder)
                        }
                        .contextMenu {
                            Button("Rename") {
                                renamingFolder = folder
                                renameText = folder.name
                            }
                            Button(role: .destructive) {
                                if let idx = store.folders.firstIndex(of: folder) {
                                    store.deleteFolders(at: IndexSet(integer: idx))
                                }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    .onDelete(perform: store.deleteFolders)
                }
                .navigationTitle("Folders")
                .toolbar {
                    Button {
                        showNewFolder = true
                        newFolderName = "New Folder"
                    } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
                }
                // New folder sheet
                .sheet(isPresented: $showNewFolder) {
                    RenameSheet(title: "New Folder",
                                text: $newFolderName,
                                onConfirm: { store.createFolder(name: newFolderName) })
                }
                // Rename folder sheet
                .sheet(item: $renamingFolder) { f in
                    RenameSheet(title: "Rename Folder",
                                text: $renameText,
                                onConfirm: { store.renameFolder(id: f.id, to: renameText) })
                }
            }
        }
    }
}
struct NotebookRow: View {
    let title: String
    let updated: Date
    let cover: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(UIColor.secondarySystemBackground))
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "pencil.and.outline")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, height: 80)
            .clipped()
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1)
                Text(updated, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

struct NotebooksView: View {
    @ObservedObject var store = NotebookStore.shared
    let folder: Folder

    // design constants
    private let cardWidth: CGFloat = 240
    private let gutter: CGFloat = 24
    private let rowSpacing: CGFloat = 24
    
    @State private var showNewSheet = false
    @State private var newName = ""

    // rename/delete state
    @State private var renamingNote: NotebookMeta?
    @State private var renameText = ""
    @State private var noteToDelete: NotebookMeta?
    @State private var showDeleteAlert = false

    // small helper so the compiler doesn’t choke
    private func columns(for totalWidth: CGFloat) -> [GridItem] {
        let contentWidth = totalWidth - 2 * gutter
        let perRow = max(1, Int((contentWidth + gutter) / (cardWidth + gutter)))
        return Array(
            repeating: GridItem(.fixed(cardWidth), spacing: gutter, alignment: .top),
            count: perRow
        )
    }

    var body: some View {
        let current = store.folders.first(where: { $0.id == folder.id }) ?? folder
        let currentName = current.name   // capture for use after GeometryReader

        GeometryReader { geo in
            let cols: [GridItem] = columns(for: geo.size.width)

            ScrollView {
                LazyVGrid(columns: cols, alignment: .leading, spacing: rowSpacing) {

                    // New notebook tile first (you wanted it on top)
                    Button {
                        newName = ""
                        showNewSheet = true
                    } label: {
                        AddNotebookTile()
                    }
                    .buttonStyle(.plain)

                    ForEach(current.notebooks) { nb in
                        NotebookCard(
                            folderID: current.id,
                            note: nb,
                            cover: store.coverImage(folderID: current.id, notebookID: nb.id),
                            onRename: {
                                renamingNote = nb
                                renameText = nb.title
                            },
                            onDelete: {
                                noteToDelete = nb
                                showDeleteAlert = true
                            }
                        )
                    }
                }
                .padding(.horizontal, gutter)
                .padding(.vertical, rowSpacing)
            }
        }
        .navigationTitle(currentName)
        .toolbar {
            Button {
                    newName = ""
                    showNewSheet = true
                } label: {
                    Image(systemName: "plus")
                }
        }
        .sheet(isPresented: $showNewSheet) {
            NameSheet(title: "New Notebook", text: $newName) {
                let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = store.createNotebook(in: folder.id,
                                         title: name.isEmpty ? "New Notebook" : name)
            }
        }
        .sheet(item: $renamingNote) { nb in
            RenameSheet(title: "Rename Notebook", text: $renameText) {
                store.renameNotebook(folderID: folder.id, notebookID: nb.id, to: renameText)
            }
        }
        .alert("Delete this notebook?",
               isPresented: $showDeleteAlert,
               presenting: noteToDelete) { nb in
            Button("Delete", role: .destructive) {
                store.deleteNotebook(folderID: folder.id, notebookID: nb.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { nb in
            Text("“\(nb.title)” will be removed permanently.")
        }
    }
}

// Small subview = happier type-checker
struct NotebookCard: View {
    let folderID: UUID
    let note: NotebookMeta
    let cover: UIImage?
    var onRename: () -> Void
    var onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink {
                ContentView(folderID: folderID, notebookID: note.id)
                    .navigationTitle(note.title)
            } label: {
                NotebookTile(title: note.title, updated: note.updated, cover: cover)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename", systemImage: "pencil", action: onRename)
                Divider()
                Button("Delete",systemImage: "trash", role: .destructive, action: onDelete)
            }

            Menu {
                Button("Rename", systemImage: "pencil", action: onRename) 
                Button("Delete",systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
            .buttonStyle(.plain)
        }
    }
}
struct AddNotebookTile: View {
    var body: some View {
        VStack(alignment: .center, spacing: 0) {

            // cover-sized area so height matches real cards
            ZStack {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(
                width: NotebookTile.cardWidth,
                height: NotebookTile.cardWidth / NotebookTile.coverAspect
            )
            .clipped()

            // footer sized exactly like NotebookTile
            VStack(spacing: 1) {
                Text("New Notebook").font(.headline)
                Text(" ") // keeps height consistent with date line; leave blank
                    .font(.caption)
                    .opacity(0)
            }
            .frame(height: NotebookTile.textBlockHeight, alignment: .center)
            .padding(.horizontal, 12)   // match whatever you used in NotebookTile
            .padding(.vertical, 6)
        }
        .frame(width: NotebookTile.cardWidth) // 🔒 same width as other cards
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.black.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .contentShape(Rectangle())
    }
}
struct NameSheet: View {
    let title: String
    @Binding var text: String
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField("Name", text: $text)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .overlay(alignment: .trailing) {
                            if !text.isEmpty {
                                Button {
                                    text = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.trailing, 6)
                            }
                        }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onConfirm(); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
// Reusable small rename sheet
private struct RenameSheet: View {
    let title: String
    @Binding var text: String
    var onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(title, text: $text)
                    .textInputAutocapitalization(.words)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onConfirm(); dismiss() }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
