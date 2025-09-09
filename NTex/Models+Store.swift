import SwiftUI
import PencilKit

// ============ Models ============
struct Folder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var created: Date = .now
    var notebooks: [NotebookMeta] = []
}

struct NotebookMeta: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var created: Date = .now
    var updated: Date = .now
}

// ============ Store ============
final class NotebookStore: ObservableObject {
    static let shared = NotebookStore()

    @Published var folders: [Folder] = []

    private let base: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("NTex", isDirectory: true)
    }()
    private var stateURL: URL { base.appendingPathComponent("state.json") }

    private init() { loadState() }

    // ---- State (folders & notebook metadata) ----
    private func loadState() {
        ensureDir(base)
        if let data = try? Data(contentsOf: stateURL),
           let f = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = f
        } else {
            // First run: one default folder
            let f = Folder(name: "My Notes")
            folders = [f]
            ensureDir(dir(for: f.id))
            saveState()
        }
    }

    private func saveState() {
        ensureDir(base)
        if let data = try? JSONEncoder().encode(folders) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }

    private func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // ---- Folder ops ----
    func createFolder(name: String = "New Folder") {
        let f = Folder(name: name)
        folders.insert(f, at: 0)
        ensureDir(dir(for: f.id))
        saveState()
    }

    func renameFolder(id: UUID, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[i].name = name
        saveState()
    }

    func deleteFolders(at offsets: IndexSet) {
        for i in offsets {
            let id = folders[i].id
            try? FileManager.default.removeItem(at: dir(for: id))
        }
        folders.remove(atOffsets: offsets)
        saveState()
    }

    // ---- Notebook ops ----
    @discardableResult
    func createNotebook(in folderID: UUID, title: String = "New Notebook") -> NotebookMeta {
        guard let fi = folders.firstIndex(where: { $0.id == folderID }) else { return NotebookMeta(title: title) }
        let nb = NotebookMeta(title: title)
        folders[fi].notebooks.insert(nb, at: 0)
        ensureDir(dir(for: folderID, notebookID: nb.id))
        saveState()
        return nb
    }

    func renameNotebook(folderID: UUID, notebookID: UUID, to title: String) {
        guard let fi = folders.firstIndex(where: { $0.id == folderID }),
              let ni = folders[fi].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
        folders[fi].notebooks[ni].title = title
        folders[fi].notebooks[ni].updated = .now
        saveState()
    }

    func deleteNotebook(folderID: UUID, notebookID: UUID) {
        guard let fi = folders.firstIndex(where: { $0.id == folderID }),
              let ni = folders[fi].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
        try? FileManager.default.removeItem(at: dir(for: folderID, notebookID: notebookID))
        folders[fi].notebooks.remove(at: ni)
        saveState()
    }

    // ---- Note content I/O ----
    struct NotebookContent {
        var drawing: PKDrawing
        var latexText: String
        var pickedImage: UIImage?
    }

    func loadContent(folderID: UUID, notebookID: UUID) -> NotebookContent {
        let d = dir(for: folderID, notebookID: notebookID)
        let drawingURL = d.appendingPathComponent("drawing.data")
        let latexURL   = d.appendingPathComponent("latex.txt")
        let imageURL   = d.appendingPathComponent("image.png")

        let drawing = (try? PKDrawing(data: Data(contentsOf: drawingURL))) ?? PKDrawing()
        let latex   = (try? String(contentsOf: latexURL, encoding: .utf8)) ?? ""
        let image   = UIImage(contentsOfFile: imageURL.path)

        return NotebookContent(drawing: drawing, latexText: latex, pickedImage: image)
    }

    func saveContent(folderID: UUID, notebookID: UUID,
                     drawing: PKDrawing, latexText: String, pickedImage: UIImage?,
                     updateCover: Bool = false) {
        let d = dir(for: folderID, notebookID: notebookID)
        ensureDir(d)
        do {
            try drawing.dataRepresentation().write(to: d.appendingPathComponent("drawing.data"), options: .atomic)
            try latexText.data(using: .utf8)?.write(to: d.appendingPathComponent("latex.txt"), options: .atomic)
            if let img = pickedImage, let data = img.pngData() {
                try data.write(to: d.appendingPathComponent("image.png"), options: .atomic)
            }
            if updateCover {
                writeCover(folderID: folderID, notebookID: notebookID,
                           drawing: drawing, pickedImage: pickedImage)
            }
        } catch {
            print("NTex save error:", error)
        }
        touchUpdated(folderID: folderID, notebookID: notebookID)
    }
    private func touchUpdated(folderID: UUID, notebookID: UUID) {
        guard let fi = folders.firstIndex(where: { $0.id == folderID }),
              let ni = folders[fi].notebooks.firstIndex(where: { $0.id == notebookID }) else { return }
        folders[fi].notebooks[ni].updated = .now
        saveState()
    }
    // MARK: - Cover thumbnails

    func coverImage(folderID: UUID, notebookID: UUID) -> UIImage? {
        let url = coverURL(folderID: folderID, notebookID: notebookID)
        return UIImage(contentsOfFile: url.path)
    }

    private func coverURL(folderID: UUID, notebookID: UUID) -> URL {
        dir(for: folderID, notebookID: notebookID).appendingPathComponent("cover.png")
    }

    /// Render a 3:2 "first page" style cover from the current drawing/photo.
    private func writeCover(folderID: UUID, notebookID: UUID,
                            drawing: PKDrawing, pickedImage: UIImage?) {
        let size = CGSize(width: 1200, height: 800)   // 3:2
        UIGraphicsBeginImageContextWithOptions(size, true, 2.0)
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))

        // If there's a photo, draw it first (aspect-fit)
        if let base = pickedImage {
            let r = aspectFitRect(imageSize: base.size, bounds: CGRect(origin: .zero, size: size))
            base.draw(in: r)
        }

        // Then draw the handwriting (also aspect-fit). Slight inset so it breathes.
        if !drawing.bounds.isEmpty {
            let img = drawing.image(from: drawing.bounds, scale: 2.0)
            let r = aspectFitRect(imageSize: img.size, bounds: CGRect(origin: .zero, size: size)).insetBy(dx: 24, dy: 24)
            img.draw(in: r, blendMode: .normal, alpha: pickedImage == nil ? 1.0 : 0.9)
        }

        let cover = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        if let cover, let data = cover.pngData() {
            try? data.write(to: coverURL(folderID: folderID, notebookID: notebookID), options: .atomic)
        }
    }

    private func aspectFitRect(imageSize: CGSize, bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let s = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        let x = bounds.midX - w/2, y = bounds.midY - h/2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // ---- Paths ----
    private func dir(for folderID: UUID) -> URL {
        base.appendingPathComponent(folderID.uuidString, isDirectory: true)
    }
    private func dir(for folderID: UUID, notebookID: UUID) -> URL {
        dir(for: folderID).appendingPathComponent(notebookID.uuidString, isDirectory: true)
    }
}
