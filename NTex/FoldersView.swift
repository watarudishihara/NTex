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
            ScrollView {
                let cols = [GridItem(.adaptive(minimum: 200, maximum: 260),
                                     spacing: 16, alignment: .top)]

                LazyVGrid(columns: cols, spacing: 16) {
                    NewFolderTile {                 // defaults → title “New Folder”, square
                        newFolderName = "New Folder"
                        showNewFolder = true
                    }

                    // Folder tiles
                    ForEach(store.folders) { f in
                        NavigationLink {
                            NotebooksView(folder: f).navigationTitle(f.name)
                        } label: {
                            FolderTile(name: f.name, count: f.notebooks.count)
                                .aspectRatio(1, contentMode: .fit)   // ← square cell
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Folders")
            .toolbar {
                // keep your existing add button too, if you like
                Button {
                    showNewFolder = true
                    newFolderName = "New Folder"
                } label: { Label("Add Folder", systemImage: "folder.badge.plus") }
            }
            // keep your existing sheets
            .sheet(isPresented: $showNewFolder) {
                RenameSheet(title: "New Folder",
                            text: $newFolderName) {
                    store.createFolder(name: newFolderName)
                }
            }
            .sheet(item: $renamingFolder) { f in
                RenameSheet(title: "Rename Folder",
                            text: $renameText,
                            onConfirm: { store.renameFolder(id: f.id, to: renameText) })
            }
        }
    }
}
private enum FolderTileConst {
    static let minWidth: CGFloat = 200      // target cell width
    static let maxWidth: CGFloat = 260      // can grow on big screens
    static let gridSpacing: CGFloat = 16
    static let corner: CGFloat = 16
}
// MARK: - Folder-shaped tile (self-contained color fill)
private enum FolderColors {
    static let blue   = Color(red: 0.68, green: 0.83, blue: 1.00)  // mac-ish blue
    static let lightBlue  = Color(red: 0.44, green: 0.66, blue: 1.00)
    static let manila = Color(red: 0.95, green: 0.80, blue: 0.40)  // classic folder yellow
    static let green  = Color(red: 0.43, green: 0.80, blue: 0.55)  // optional extra
}

// Optional: stable palette pick by name (same every run)
private func palettePick(for name: String) -> Color {
    let palette: [Color] = [FolderColors.blue, FolderColors.manila, FolderColors.green, FolderColors.lightBlue]
    var h: UInt32 = 0x811C9DC5; for b in name.utf8 { h ^= UInt32(b); h &*= 16777619 }
    return palette[Int(h % UInt32(palette.count))]
}

private struct FolderTile: View {
    @Environment(\.colorScheme) private var scheme
    let name: String
    let count: Int

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = w                      // square cell from the grid

            // stable color (no .opacity() inside gradient — must be Colors)
            let fill: Color = FolderColors.blue

            let shape = FolderShape(
              bodyRadius: 12,
              tabRadius: 12,
              tabWidthRatio: 0.4,   // wider tab
              tabHeightRatio: 0.08,  // a bit shorter
              tabOffsetXRatio: 0.00, // push to the left edge
              joinRadiusRatio: 0.5  // smoother blend
            )
            let grooveHeight   = max(2, w * 0.035)    // <- make this bigger/smaller for thickness
            let grooveTop      = 0.16 * h      // <- move up/down (distance from top of folder body)
            let grooveInset    = w * 0.08             // <- left/right inset; lower = longer bar
            let grooveCorner   = w * 0.04             // <- 0 = straight, higher = more pill-like
            let grooveOpacity  = 0.12

            ZStack {
                shape
                    .fill(fill)
                    .overlay(shape.stroke(.black.opacity(0.08), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                    .compositingGroup()

                // pocket line
                RoundedRectangle(cornerRadius: grooveCorner)
                    .fill(Color.black.opacity(grooveOpacity))
                    .frame(height: grooveHeight)
                    .padding(.horizontal, grooveInset)
                    .padding(.top, grooveTop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .mask(shape)
                    .allowsHitTesting(false)

                // label chip
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline).lineLimit(2)
                    Text(count == 1 ? "1 notebook" : "\(count) notebooks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, w * 0.05)
                .padding(.vertical, w * 0.03)
                .background(
                    RoundedRectangle(cornerRadius: w * 0.04)
                        .fill(Color(UIColor.systemBackground).opacity(0.88))
                        .overlay(
                            RoundedRectangle(cornerRadius: w * 0.04)
                                .stroke(.black.opacity(0.07), lineWidth: 0.5)
                        )
                )
                .padding(w * 0.06)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            .frame(width: w, height: h)
            .contentShape(shape)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// deterministic pastel (hue, saturation)
private func folderHueSat(for name: String) -> (Double, Double) {
    let hues: [Double] = [0.58, 0.11, 0.28, 0.75, 0.03] // blue, orange, pink, purple, red
    let i = abs(name.hashValue) % hues.count
    return (hues[i], 0.55)
}

// MARK: - Folder silhouette
// One continuous outline (tab blends smoothly into the body)
struct FolderShape: Shape {
    var bodyRadius: CGFloat = 16
    var tabRadius: CGFloat  = 8
    var tabWidthRatio: CGFloat = 0.9
    var tabHeightRatio: CGFloat = 0.22
    var tabOffsetXRatio: CGFloat = 0.10
    var joinRadiusRatio: CGFloat = 0.50

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r  = min(bodyRadius, min(w, h) * 0.25)
        let tH = max(10, min(h * tabHeightRatio, r * 1.4))
        let tW = max(36, w * tabWidthRatio)
        let tX = max(0, w * tabOffsetXRatio)         // allow tab to sit at x≈0
        let j  = min(r * 0.9, tH * joinRadiusRatio)
        let tl = max(2, tabRadius)

        // If tab is close to the left edge, don't draw the body's top-left corner.
        let cutLeftCorner = tX <= r * 0.6

        var p = Path()

        // --- tab top edge ---
        p.move(to: CGPoint(x: tX + tl, y: 0))
        p.addLine(to: CGPoint(x: tX + tW - tl, y: 0))
        p.addQuadCurve(to: CGPoint(x: tX + tW, y: tl),
                       control: CGPoint(x: tX + tW, y: 0))
        // tab right side to blend
        p.addLine(to: CGPoint(x: tX + tW, y: tH - j))
        p.addQuadCurve(to: CGPoint(x: tX + tW + j, y: tH),
                       control: CGPoint(x: tX + tW, y: tH))

        // --- top edge to top-right corner ---
        p.addLine(to: CGPoint(x: w - r, y: tH))
        p.addQuadCurve(to: CGPoint(x: w, y: tH + r),
                       control: CGPoint(x: w, y: tH))

        // right, bottom, left sides
        p.addLine(to: CGPoint(x: w, y: h - r))
        p.addQuadCurve(to: CGPoint(x: w - r, y: h),
                       control: CGPoint(x: w, y: h))
        p.addLine(to: CGPoint(x: r, y: h))
        p.addQuadCurve(to: CGPoint(x: 0, y: h - r),
                       control: CGPoint(x: 0, y: h))

        // --- left side up to the tab join ---
        if cutLeftCorner {
            // go straight up; no rounded body corner when tab is flush-left
            p.addLine(to: CGPoint(x: 0, y: tH))
        } else {
            // keep the normal top-left rounded corner
            p.addLine(to: CGPoint(x: 0, y: tH + r))
            p.addQuadCurve(to: CGPoint(x: r, y: tH),
                           control: CGPoint(x: 0, y: tH))
        }

        // blend into the tab on the left
        p.addLine(to: CGPoint(x: max(0, tX - j), y: tH))
        p.addQuadCurve(to: CGPoint(x: tX, y: tH - j),
                       control: CGPoint(x: tX, y: tH))
        p.addLine(to: CGPoint(x: tX, y: tl))
        p.addQuadCurve(to: CGPoint(x: tX + tl, y: 0),
                       control: CGPoint(x: tX, y: 0))

        p.closeSubpath()
        return p
    }
}

// MARK: - Deterministic soft tint (pastel)
private func folderTint(for name: String) -> Color {
    let hues: [Double] = [0.58, 0.11, 0.28, 0.75, 0.03] // blue, orange, pink, purple, red
    let i = abs(name.hashValue) % hues.count
    // crank saturation a bit so it’s visible in dark mode, keep brightness high
    return Color(hue: hues[i], saturation: 0.55, brightness: 0.95)
}

private struct NewFolderTile: View {
    var title: String = "New Folder"
    var icon: String  = "folder.badge.plus"
    var aspect: CGFloat = 1.0
    var action: () -> Void = {}

    private struct PressStyle: ButtonStyle {
        var cornerRadius: CGFloat = 16
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Color.black.opacity(configuration.isPressed ? 0.06 : 0))
                )
                .animation(.spring(response: 0.22, dampingFraction: 0.85),
                           value: configuration.isPressed)
        }
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                    .foregroundStyle(.secondary)
                VStack(spacing: 10) {
                    Image(systemName: icon).font(.system(size: 36, weight: .semibold))
                    Text(title).font(.subheadline)
                }
                .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
            .aspectRatio(aspect, contentMode: .fit)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(title)
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

private enum NoteGrid {
    static let aspect: CGFloat = 1.0   // square cards; change to 4.0/3.0 later if you prefer
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
            let cols = columns(for: geo.size.width)   // <- use the helper
            ScrollView {
                LazyVGrid(columns: cols, alignment: .leading, spacing: rowSpacing) {

                    // match card width for the “new notebook” tile too
                    AddNotebookTile()
                        .onTapGesture {
                            newName = "Untitled"
                            showNewSheet = true
                        }

                    ForEach(current.notebooks) { nb in
                        NotebookCard(
                            folderID: current.id,
                            note: nb,
                            cover: store.coverImage(folderID: current.id, notebookID: nb.id),
                            onRename: { renamingNote = nb; renameText = nb.title },
                            onDelete: { noteToDelete = nb; showDeleteAlert = true }
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
