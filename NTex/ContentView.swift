import SwiftUI
import PhotosUI
import PencilKit
import WebKit
import UIKit

struct Notebook: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var created: Date
}

struct HomeView: View {
    @EnvironmentObject var store: NotebookStore
    @ToolbarContentBuilder
    private var homeToolbar: some ToolbarContent {
        ToolbarItem(placement: {
            if #available(iOS 17.0, *) { return .topBarTrailing } else { return .navigationBarTrailing }
        }()) {
            Button {
                guard let id = store.folders.first?.id else { return }
                _ = store.createNotebook(in: id, title: "New Notebook")
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(store.folders.isEmpty)
        }
    }

    var body: some View {
        NavigationStack {
            if let folder = store.folders.first {
                List {
                    ForEach(folder.notebooks) { nb in          // <- use `folder`, not `current`
                        NavigationLink {
                            ContentView(folderID: folder.id, notebookID: nb.id)
                                .navigationTitle(nb.title)
                        } label: {
                            NotebookTile(
                                title: nb.title,
                                updated: nb.updated,
                                cover: store.coverImage(folderID: folder.id, notebookID: nb.id)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in
                        let ids = idx.map { folder.notebooks[$0].id }
                        ids.forEach { store.deleteNotebook(folderID: folder.id, notebookID: $0) }
                    }
                }
                .navigationTitle("NTex Notebooks")
            } else {
                // First run: create a default folder
                VStack {
                    Text("No folders yet")
                    Button("Create ‘My Notes’") { store.createFolder(name: "My Notes") }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar { homeToolbar }
        
    }
}
struct NotebookTile: View {
    let title: String
    let updated: Date
    let cover: UIImage?

    static let cardWidth: CGFloat = 240
    static let coverAspect: CGFloat = 4.0/3.0
    static let textBlockHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // COVER (no background rect here)
            ZStack {
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
            .frame(
                width: Self.cardWidth,
                height: Self.cardWidth / Self.coverAspect
            )
            .clipped() // trim any overflow from scaledToFill

            // TEXT (fixed height so all cards match)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(2)
                Text(updated, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: Self.textBlockHeight, alignment: .topLeading)
            .padding(.horizontal, 12)     // ← inset from left/right
            .padding(.vertical, 2)       // ← breathing room top/bottom
        }
        .frame(width: Self.cardWidth)                 // lock width
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.black.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16)) // clip bg + image together
        .compositingGroup()                            // make shadow clean
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        .contentShape(Rectangle())
    }
}
// MARK: - ContentView
enum ToolType: Equatable {
    case pen
    case marker
    case eraser
    case lasso
    case shape
}
enum EraseMode: String, CaseIterable, Identifiable {
    case object, pixel
    var id: String { rawValue }
}

enum ShapeKind: String, CaseIterable, Identifiable {
    case line, arrow, rectangle, ellipse
    var id: String { rawValue }
}

struct ContentView: View {
    // NOTE TARGETS
    let folderID: UUID
    let notebookID: UUID

    // Store for load/save
    @EnvironmentObject private var store: NotebookStore

    // Base URL persisted. Simulator uses localhost; device starts empty.
    @AppStorage("baseURL") private var baseURL: String = {
        #if targetEnvironment(simulator)
        return "http://127.0.0.1:8000"
        #else
        return ""
        #endif
    }()
    
    //tools
    @State private var strokeWidth: CGFloat = 5

    // Last-picked width per tool
    @State private var penWidth: CGFloat = 5
    @State private var markerWidth: CGFloat = 10   // a bit thicker by default
    
    //eraser
    @State private var eraseMode: EraseMode = .pixel
    @State private var eraserRadius: CGFloat = 12
    @State private var eraserWidthFavorites: [CGFloat] = [8, 12, 20]

    // Viewport from PKCanvasView so we can convert overlay points -> canvas content coords
    @State private var canvasViewport = EraserOverlay.CanvasViewport()

    // 3 quick-swap width presets per tool
    @State private var penWidthFavorites:    [CGFloat] = [3, 5, 8]
    @State private var markerWidthFavorites: [CGFloat] = [8, 12, 18]

    // shapes
    @State private var currentShape: ShapeKind = .rectangle
    @State private var shapes: [ShapeItem] = []
    @State private var dragStart: CGPoint? = nil
    @State private var dragRect: CGRect? = nil
    
    @State private var showToolOptions = false  // popover for colors/width/shape

    // canvas undo
    @State private var canvasUndo: UndoManager? = nil
    @State private var currentColor: Color = .black
    @State private var penColor: Color = .black
    @State private var markerColor: Color = .pink
    @State private var penFavorites:    [Color] = [.black, .blue, .red]
    @State private var markerFavorites: [Color] = [.yellow, .pink, .blue]
    
    // --- UI / note state ---
    @State private var drawing = PKDrawing()
    @State private var pickedImage: UIImage? = nil
    @State private var showCropper = false
    @State private var isConverting = false
    @State private var showSettings = false
    @State private var errorMessage: String? = nil
    @State private var showRightPanel = true
    @State private var panelMode: PanelMode = .preview
    @State private var showShare = false
    @State private var shareURL: URL? = nil
    @State private var currentTool: ToolType = .pen
    @State private var latexText: String = ""      // editor text
    @State private var previewLatex: String = ""   // rendered text

    // Camera / photos
    @State private var showCamera = false
    @State private var photosItem: PhotosPickerItem?

    // Right panel width
    @State private var panelWidth: CGFloat = 360
    // Keep the heavy layout out of `body` so the compiler is happy
    @ViewBuilder
    private var layout: some View {
        HStack(spacing: 0) {
            leftPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(UIColor.systemBackground))

            if showRightPanel {
                rightPane
                    .frame(width: panelWidth)
                    .overlay(resizeHandle, alignment: .leading)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // iOS 16/17-safe placements
    private var leadingPlacement: ToolbarItemPlacement {
        if #available(iOS 17.0, *) { return .topBarLeading } else { return .navigationBarLeading }
    }
    private var trailingPlacement: ToolbarItemPlacement {
        if #available(iOS 17.0, *) { return .topBarTrailing } else { return .navigationBarTrailing }
    }

    // Your toolbar, expressed as ToolbarContent (no ambiguity)
    @ToolbarContentBuilder
    private var contentToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: leadingPlacement) {
            // Settings
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }

        ToolbarItemGroup(placement: trailingPlacement) {
            Button {
                withAnimation(.easeInOut) { showRightPanel.toggle() }
            } label: {
                // pick the icon you like:
                // "sidebar.trailing" / "sidebar.leading" (your original)
                // or "sidebar.right" / "sidebar.left" on iOS 17+
                Image(systemName: showRightPanel ? "sidebar.trailing" : "sidebar.leading")
            }
            .help(showRightPanel ? "Hide LaTeX panel" : "Show LaTeX panel")
            // .keyboardShortcut("[", modifiers: [.command, .shift]) // optional

            // Undo / Redo (these stay as-is)

            // Tool options (colors, thickness, shape picker)
            .popover(isPresented: $showToolOptions, arrowEdge: .top) {
                ToolOptionsPopover(
                    currentTool: $currentTool,
                    currentShape: $currentShape,
                    color: $currentColor,          // <- pass ACTIVE color
                    strokeWidth: $strokeWidth
                )
                .padding()
                .frame(width: 340)
            }

            // Export .tex
            if !latexText.isEmpty {
                Button {
                    shareURL = makeTempTexFile(text: latexText)
                    showShare = true
                } label: {
                    Label("Export .tex", systemImage: "square.and.arrow.up")
                }
            }
        }
    }



    // Small helpers so the onChange/.task lines stay tidy
    private func loadNote() {
        let c = store.loadContent(folderID: folderID, notebookID: notebookID)
        drawing = c.drawing
        pickedImage = c.pickedImage
        latexText = c.latexText
        previewLatex = cleanForKaTeX(latexText)
    }

    private func save(updateCover: Bool = false) {
        store.saveContent(folderID: folderID, notebookID: notebookID,
                          drawing: drawing, latexText: latexText, pickedImage: pickedImage,
                          updateCover: updateCover)
    }
    
    private var resizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 20, height: 200) // 200pt tall instead of full height
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let newWidth = max(280, min(600, panelWidth - value.translation.width))
                        panelWidth = newWidth
                    }
            )
            .overlay(
                Rectangle()
                    .fill(Color.secondary.opacity(0.4)) // thin line
                    .frame(width: 2, height: 50)       // same shorter height
                    .padding(.leading, -3),              // inset from edge
                alignment: .center
            )
    }


    var body: some View {
        NavigationStack {
            layout                                   // only the big HStack lives here
        }
        // Attach ALL modifiers to the NavigationStack (not the HStack)
        .sheet(isPresented: $showSettings) { SettingsView(baseURL: $baseURL) }
        .sheet(isPresented: $showCropper) {
            if let img = currentImageForCrop() {
                CropperSheet(image: img) { self.pickedImage = $0 }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { uiImage in pickedImage = uiImage.fixedOrientation() }
        }
        .sheet(isPresented: $showShare) {
            if let url = shareURL { ShareSheet(items: [url]) }
        }
        .alert("Error",
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { _ in errorMessage = nil })) {
            Button("OK", role: .cancel) { }
        } message: { Text(errorMessage ?? "") }

        .task { loadNote() }
        .onChange(of: drawing)    { _, _ in save() }
        .onChange(of: latexText)  { _, _ in save() }
        .onChange(of: pickedImage){ _, _ in save(updateCover: true) }
        .onDisappear { save(updateCover: true) }

        .toolbar { contentToolbar }                  // explicit ToolbarContent below
    }

    // MARK: - Views

    private var leftPane: some View {
        VStack(spacing: 0) {
            if let img = pickedImage {
                ZoomableImage(image: Image(uiImage: img))
                    .overlay(alignment: .bottomTrailing) {
                        HStack {
                            Button {
                                showCropper = true
                            } label: {
                                Label("Crop", systemImage: "crop")
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(8)

                            Button(role: .destructive) {
                                pickedImage = nil
                            } label: {
                                Label("Clear Image", systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.bordered)
                            .padding(8)
                        }
                    }
            } else {
                CanvasToolBar(
                    currentTool: $currentTool,
                    currentShape: $currentShape,
                    color: $currentColor,
                    strokeWidth: $strokeWidth,
                    showToolOptions: $showToolOptions,
                    penFavorites: $penFavorites,
                    markerFavorites: $markerFavorites,
                    penWidthFavorites: $penWidthFavorites,
                    markerWidthFavorites: $markerWidthFavorites,
                    eraserRadius: $eraserRadius,                 // NEW
                    eraserWidthFavorites: $eraserWidthFavorites, // NEW
                    eraseMode: $eraseMode,                       // NEW
                    canUndo: (canvasUndo?.canUndo ?? false),
                    canRedo: (canvasUndo?.canRedo ?? false),
                    onUndo: { canvasUndo?.undo() },
                    onRedo: { canvasUndo?.redo() }
                )
                ZStack {
                    PencilCanvas(
                        drawing: $drawing,
                        tool: $currentTool,
                        penColor: $currentColor,
                        strokeWidth: $strokeWidth,
                        undoManager: $canvasUndo,
                        eraseMode: $eraseMode,
                        viewport: $canvasViewport
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                    .contentShape(Rectangle())
                    // Pixel-eraser overlay (captures polyline and performs stroke splitting)
                    if currentTool == .eraser && eraseMode == .pixel {
                        EraserOverlay(radius: eraserRadius, viewport: $canvasViewport) { polyInCanvas in
                            let before = drawing
                            // Convert radius to canvas-content units (account for zoom)
                            let rInCanvas = max(0.5, eraserRadius / max(0.001, canvasViewport.zoomScale))
                            let after = StrokeEraser.erase(before, with: polyInCanvas, radius: rInCanvas)
                            if before != after {
                                // inside EraserOverlay onEnded { polyInCanvas in ... }
                                let before = drawing
                                let rInCanvas = max(0.5, eraserRadius / max(0.001, canvasViewport.zoomScale))
                                let after = StrokeEraser.erase(before, with: polyInCanvas, radius: rInCanvas)
                                guard before != after else { return }

                                // apply
                                drawing = after

                                // make a target that knows how to write back into @State
                                let target = DrawingUndoTarget { newVal in
                                    self.drawing = newVal
                                }

                                // group + name the action and make redo work
                                canvasUndo?.beginUndoGrouping()
                                canvasUndo?.registerUndo(withTarget: target) { t in
                                    let current = self.drawing
                                    t.set(before) // undo -> restore "before"
                                    // register redo
                                    self.canvasUndo?.registerUndo(withTarget: target) { t2 in
                                        t2.set(current)
                                    }
                                }
                                canvasUndo?.setActionName("Erase")
                                canvasUndo?.endUndoGrouping()
                            }
                        }
                        .transition(.opacity)
                    }

                    // Shape overlay ON TOP of the canvas
                    if currentTool == .shape {
                        ShapeDrawOverlay(currentShape: $currentShape,
                                         dragStart: $dragStart,
                                         dragRect: $dragRect,
                                         shapes: $shapes)
                            .allowsHitTesting(true)
                            .transition(.opacity)
                    }

                    // Lasso HUD anchored bottom-trailing
                    if currentTool == .lasso {
                        lassoHUD
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(16)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .background(Color.white)
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .onChange(of: currentTool, initial: true) { _, newTool in
            // color handoff (you already had this)
            currentColor = (newTool == .marker) ? markerColor : penColor
            // width handoff
            strokeWidth = (newTool == .marker) ? markerWidth : penWidth
        }

        .onChange(of: currentColor) { _, newColor in
            if currentTool == .marker { markerColor = newColor } else { penColor = newColor }
        }

        // remember last-picked width for the active tool
        .onChange(of: strokeWidth) { _, newValue in
            if currentTool == .marker { markerWidth = newValue } else { penWidth = newValue }
        }
    }
    private var lassoHUD: some View {
        HStack(spacing: 8) {
            Button {
                UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy), to: nil, from: nil, for: nil)
            } label: { Label("Copy", systemImage: "doc.on.doc") }

            Button {
                UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.copy), to: nil, from: nil, for: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.paste), to: nil, from: nil, for: nil)
                }
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }

            Button(role: .destructive) {
                UIApplication.shared.sendAction(#selector(UIResponderStandardEditActions.delete), to: nil, from: nil, for: nil)
            } label: { Label("Delete", systemImage: "trash") }
        }
        .buttonStyle(.borderedProminent)
        .tint(.secondary)
    }

    private var rightPane: some View {
        VStack(spacing: 8) {
            Picker("", selection: $panelMode) {
                Text("Editor").tag(PanelMode.editor)
                Text("Preview").tag(PanelMode.preview)
            }
            .pickerStyle(.segmented)
            .padding([.top, .horizontal])

            switch panelMode {
            case .editor:
                TextEditor(text: $latexText)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)

            case .preview:
                MathLabel(latex: previewLatex.isEmpty ? "\\;" : previewLatex)
                    .id(previewLatex) // <-- ensures SwiftUI rebuilds when previewLatex changes
                    .frame(maxWidth: .infinity,maxHeight: .infinity, alignment: .leading)
                    .padding()
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                    .padding()
            }

            Spacer()

            HStack {
                Button {
                    previewLatex = latexText  // copy whatever is in editor into preview
                    print("Rendering:", previewLatex) // debug
                    withAnimation { panelMode = .preview }
                } label: {
                    Label("Render LaTeX", systemImage: "eye")
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await convertCurrent() }
                } label: {
                    if isConverting {
                        ProgressView()
                    } else {
                        Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isConverting || !isServerConfigured)
            }
            .padding(.bottom, 12)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }

    // MARK: Convert

    private var isServerConfigured: Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty
    }

    private func convertCurrent() async {
        guard isServerConfigured else {
            errorMessage = "Invalid server URL"
            return
        }
        isConverting = true
        defer { isConverting = false }

        let imageToSend: UIImage
        if let img = pickedImage {
            imageToSend = img.withBackground(color: .white)
        } else {
            let bounds = drawing.bounds.isEmpty ? CGRect(x: 0, y: 0, width: 2048, height: 2732) : drawing.bounds
            let img = drawing.image(from: bounds, scale: 2.0)
            imageToSend = img.withBackground(color: .white)
        }

        do {
            let latex = try await LatexService.convert(image: imageToSend, baseURLString: baseURL)
            latexText = latex
            previewLatex = cleanForKaTeX(latex)   // <-- cleaned version goes to KaTeX
            if showRightPanel == false {
                withAnimation { showRightPanel = true }
                panelMode = .preview
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func currentImageForCrop() -> UIImage? {
        if let img = pickedImage { return img }
        return nil
    }
}

// MARK: - Panel mode
private enum PanelMode: String, Hashable {
    case editor, preview
}

//MARK: Tools Picker Strip and Tool Options
private struct ToolPickerStrip: View {
    @Binding var currentTool: ToolType
    var body: some View {
        Picker("", selection: $currentTool) {
            Image(systemName: "pencil.tip").tag(ToolType.pen)
            Image(systemName: "highlighter").tag(ToolType.marker)
            Image(systemName: "eraser").tag(ToolType.eraser)
            Image(systemName: "selection.pin.in.out").tag(ToolType.lasso)
            Image(systemName: "square.on.circle").tag(ToolType.shape)
        }
        .pickerStyle(.segmented)
    }
}
private struct CanvasToolBar: View {
    @State private var showWidthPopover = false
    @Binding var currentTool: ToolType
    @Binding var currentShape: ShapeKind
    @Binding var color: Color
    @Binding var strokeWidth: CGFloat
    @Binding var showToolOptions: Bool

    @Binding var penFavorites: [Color]
    @Binding var markerFavorites: [Color]

    @Binding var penWidthFavorites: [CGFloat]
    @Binding var markerWidthFavorites: [CGFloat]
    
    //for eraser
    @Binding var eraserRadius: CGFloat
    @Binding var eraserWidthFavorites: [CGFloat]
    @Binding var eraseMode: EraseMode

    var canUndo: Bool
    var canRedo: Bool
    var onUndo: () -> Void
    var onRedo: () -> Void

    private let swatches: [Color] = [.black, .blue, .red, .green, .orange, .yellow]

    var body: some View {
        HStack(spacing: 12) {

            // 1) Current tool (the “little slider”)
            Picker("", selection: $currentTool) {
                Image(systemName: "pencil.tip").tag(ToolType.pen)
                Image(systemName: "highlighter").tag(ToolType.marker)
                Image(systemName: "eraser").tag(ToolType.eraser)
                Image(systemName: "selection.pin.in.out").tag(ToolType.lasso)
                Image(systemName: "square.on.circle").tag(ToolType.shape)
            }
            .pickerStyle(.segmented)
            .controlSize(.regular)
            .frame(maxWidth: 320)

            // ============== ERASER UI (new) ==============
            if currentTool == .eraser {
                // mode toggle
                Picker("", selection: $eraseMode) {
                    Text("Object").tag(EraseMode.object)
                    Text("Pixel").tag(EraseMode.pixel)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)

                // three radius chips (tap = use, long-press = save)
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        let w = eraserWidthFavorites[i]
                        let demoH = max(3, min(14, w))
                        let selected = abs(eraserRadius - w) < 0.5
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(UIColor.secondarySystemBackground))
                            Capsule()
                                .fill(Color.primary.opacity(0.85))
                                .frame(width: 22, height: demoH)
                        }
                        .frame(width: 34, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(selected ? Color.blue : .white.opacity(0.7),
                                        lineWidth: selected ? 2 : 1)
                        )
                        .onTapGesture { eraserRadius = w }
                        .onLongPressGesture { eraserWidthFavorites[i] = eraserRadius }
                        .accessibilityLabel("Eraser width preset \(i+1)")
                    }
                }
                .transition(.opacity)

            } else {
                // ============== PEN / MARKER UI (your existing controls) ==============

                // Put these inside the branch to avoid "unused" warnings in eraser mode
                let favs = currentTool == .marker ? $markerFavorites : $penFavorites

                HStack(spacing: 10) {
                    // 3 quick-swap slots
                    ForEach(0..<3, id: \.self) { i in
                        let slotColor = favs.wrappedValue[i]
                        let preview = currentTool == .marker ? slotColor.opacity(0.35) : slotColor
                        Circle()
                            .fill(preview)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .overlay( // selection ring
                                Circle()
                                    .stroke(color == slotColor ? Color.blue : .clear, lineWidth: 2)
                            )
                            .onTapGesture { color = slotColor }
                            .onLongPressGesture { favs.wrappedValue[i] = color }
                            .accessibilityLabel("Favorite color \(i+1)")
                    }

                    // live color picker for fine-tuning
                    ColorPicker("", selection: $color, supportsOpacity: false)
                        .labelsHidden()

                    // width control (slider popover)
                    Button { showWidthPopover.toggle() } label: {
                        Image(systemName: "scribble.variable")
                            .imageScale(.medium)
                            .padding(.horizontal, 6)
                    }
                    .accessibilityLabel("Adjust thickness")
                    .popover(isPresented: $showWidthPopover, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Thickness").font(.headline)
                            HStack(spacing: 8) {
                                Slider(value: $strokeWidth, in: 1...20, step: 1)
                                Text("\(Int(strokeWidth))")
                                    .monospacedDigit()
                                    .frame(width: 32, alignment: .trailing)
                            }
                            Text("Tip: long-press a width chip to save this value.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .frame(width: 260)
                    }
                }
                .transition(.opacity)

                let wFavs = currentTool == .marker ? $markerWidthFavorites : $penWidthFavorites

                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        let w = wFavs.wrappedValue[i]
                        let demoH = max(2, min(14, w))
                        let lineColor = currentTool == .marker ? color.opacity(0.5) : color
                        let isSelected = abs(strokeWidth - w) < 0.5

                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(UIColor.secondarySystemBackground))
                            Capsule()
                                .fill(lineColor)
                                .frame(width: 22, height: demoH)
                        }
                        .frame(width: 34, height: 20)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isSelected ? Color.blue : Color.white.opacity(0.7),
                                        lineWidth: isSelected ? 2 : 1)
                        )
                        .onTapGesture { strokeWidth = w }
                        .onLongPressGesture { wFavs.wrappedValue[i] = strokeWidth }
                        .accessibilityLabel("Width preset \(i+1)")
                    }
                }
            }

            Spacer()

            // 3) Undo / Redo (right side)
            Button(action: onUndo) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!canUndo)

            Button(action: onRedo) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!canRedo)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(Divider(), alignment: .bottom)
    }
}

private struct ToolOptionsPopover: View {
    @Binding var currentTool: ToolType
    @Binding var currentShape: ShapeKind
    @Binding var color: Color
    @Binding var strokeWidth: CGFloat

    private let swatches: [Color] = [.black, .blue, .red, .green, .orange, .yellow]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if currentTool == .shape {
                Text("Shape").font(.headline)
                Picker("", selection: $currentShape) {
                    Image(systemName: "line.diagonal").tag(ShapeKind.line)
                    Image(systemName: "arrow.right").tag(ShapeKind.arrow)
                    Image(systemName: "rectangle").tag(ShapeKind.rectangle)
                    Image(systemName: "circle").tag(ShapeKind.ellipse)
                }
                .pickerStyle(.segmented)
            } else {
                Text("Color").font(.headline)
                HStack(spacing: 10) {
                    ForEach(swatches, id: \.self) { c in
                        Circle()
                            .fill(c)
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(radius: 0.5)
                            .onTapGesture { color = c }
                    }
                }
                Text("Thickness").font(.headline)
                Slider(value: $strokeWidth, in: 1...20, step: 1)
            }
        }
    }
}
// MARK: - PencilKit wrapper

import SwiftUI
import PencilKit

struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var tool: ToolType
    @Binding var penColor: Color
    @Binding var strokeWidth: CGFloat
    @Binding var undoManager: UndoManager?
    
    // Eraser
    @Binding var eraseMode: EraseMode
    @Binding var viewport: EraserOverlay.CanvasViewport

    // page config
    private let minPageHeight: CGFloat = 2000
    private let bottomHeadroom: CGFloat = 1000
    private let bottomWritingInset: CGFloat = 120   // (kept for clarity, used via applyInsets)

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> PKCanvasView {
        let v = PKCanvasView()
        context.coordinator.canvas = v

        v.delegate = context.coordinator
        v.isOpaque = true
        v.backgroundColor = .white
        #if targetEnvironment(simulator)
        v.drawingPolicy = .anyInput
        #else
        v.drawingPolicy = .pencilOnly
        #endif

        // scrolling / zoom
        v.isScrollEnabled = true
        v.minimumZoomScale = 1
        v.maximumZoomScale = 6
        v.alwaysBounceVertical = true
        v.alwaysBounceHorizontal = false
        v.contentInsetAdjustmentBehavior = .never
        v.isMultipleTouchEnabled = true
        v.contentScaleFactor = UIScreen.main.scale

        // Bindings into coordinator so we don’t rely on a stale struct copy
        context.coordinator.drawingBinding = $drawing
        context.coordinator.undoBinding = $undoManager
        context.coordinator.viewportBinding = $viewport

        // seed initial viewport + content sizing on next runloop
        DispatchQueue.main.async {
            self.applyInsets(v)
            self.ensureContentSize(v)
            context.coordinator.pushViewport(from: v)
            self.undoManager = v.undoManager
        }

        // Initial state
        v.drawing = drawing
        applyToolIfNeeded(on: v, coordinator: context.coordinator)

        return v
    }

    func updateUIView(_ v: PKCanvasView, context: Context) {
        // Refresh coordinator bindings in case the parent restructured
        context.coordinator.drawingBinding = $drawing
        context.coordinator.undoBinding = $undoManager
        context.coordinator.viewportBinding = $viewport

        // Only push drawing down if it actually changed (prevents flicker & layout thrash)
        if v.drawing != drawing {
            v.drawing = drawing
        }

        applyInsets(v)
        ensureContentSize(v)

        // Diff tool state (tool type, color, width, erase mode)
        context.coordinator.currentToolType = tool
        context.coordinator.currentPenColor = penColor
        context.coordinator.currentStrokeWidth = strokeWidth
        context.coordinator.currentEraseMode = eraseMode
        applyToolIfNeeded(on: v, coordinator: context.coordinator)
    }

    // MARK: - Coordinator

    final class Coord: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        // live canvas reference
        weak var canvas: PKCanvasView?

        // current inputs to derive toolKey
        var currentToolType: ToolType = .pen
        var currentPenColor: Color = .black
        var currentStrokeWidth: CGFloat = 5
        var currentEraseMode: EraseMode = .pixel

        // bindings
        var drawingBinding: Binding<PKDrawing>!
        var undoBinding: Binding<UndoManager?>!
        var viewportBinding: Binding<EraserOverlay.CanvasViewport>!

        // memoization to avoid redundant updates
        var lastToolKey: String = ""
        var lastGestureEnabled: Bool?
        
        //too much refreshing going on
        private var isActivelyDrawing = false
        private var pendingSync: DispatchWorkItem?

        // PKCanvasViewDelegate
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isActivelyDrawing else { return }
            scheduleSync(from: canvasView, delay: 0.12)   // coalesce small edits
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isActivelyDrawing = true
            // optional: cancel any pending sync that was queued
            pendingSync?.cancel()
            pendingSync = nil
        }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isActivelyDrawing = false
            scheduleSync(from: canvasView, delay: 0)      // commit immediately at stroke end
        }

        // UIScrollViewDelegate
        func scrollViewDidScroll(_ scrollView: UIScrollView) { pushViewport(from: scrollView) }
        func scrollViewDidZoom(_ scrollView: UIScrollView)   { pushViewport(from: scrollView) }

        func pushViewport(from scrollView: UIScrollView) {
            viewportBinding.wrappedValue = .init(
                zoomScale: scrollView.zoomScale,
                contentOffset: scrollView.contentOffset
            )
        }
        private func scheduleSync(from cv: PKCanvasView, delay: TimeInterval) {
                pendingSync?.cancel()
                let work = DispatchWorkItem { [weak self, weak cv] in
                    guard let self, let cv else { return }

                    // Push drawing + undo to SwiftUI
                    self.drawingBinding.wrappedValue = cv.drawing
                    self.undoBinding.wrappedValue = cv.undoManager

                    // Grow page AFTER stroke; avoid relayout mid-draw
                    let targetH = self.desiredContentHeight(cv)
                    if abs(cv.contentSize.height - targetH) > 1 {
                        cv.contentSize = CGSize(width: max(1, cv.bounds.width), height: targetH)
                    }
                }
                pendingSync = work
                if delay == 0 {
                    DispatchQueue.main.async(execute: work)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                }
            }

        // local copy of desired height so we can call it from delegate
        private func desiredContentHeight(_ v: PKCanvasView) -> CGFloat {
            let viewportH = max(1, v.bounds.height)
            let minH = max(2000, viewportH + 200)
            let drawingBottom = v.drawing.bounds.isEmpty ? 0 : v.drawing.bounds.maxY
            return max(minH, drawingBottom + 1000)
        }
    }

    // MARK: - Tool application (diffed)

    private func applyToolIfNeeded(on v: PKCanvasView, coordinator: Coord) {
        let key = toolKey(
            tool: coordinator.currentToolType,
            color: coordinator.currentPenColor,
            width: coordinator.currentStrokeWidth,
            eraseMode: coordinator.currentEraseMode
        )
        if key != coordinator.lastToolKey {
            // Toggle drawing gesture only when necessary
            let shouldEnableDrawing: Bool
            switch coordinator.currentToolType {
            case .pen, .marker, .shape:
                shouldEnableDrawing = true
            case .eraser:
                shouldEnableDrawing = (coordinator.currentEraseMode == .object) // vector erase draws; pixel erase uses overlay
            case .lasso:
                shouldEnableDrawing = false
            }

            if coordinator.lastGestureEnabled != shouldEnableDrawing {
                v.drawingGestureRecognizer.isEnabled = shouldEnableDrawing
                coordinator.lastGestureEnabled = shouldEnableDrawing
            }

            // Apply concrete PKTool
            switch coordinator.currentToolType {
            case .pen:
                let ui = UIColor(coordinator.currentPenColor)
                    .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                v.tool = PKInkingTool(.pen, color: ui, width: max(1, coordinator.currentStrokeWidth))

            case .marker:
                let ui = UIColor(coordinator.currentPenColor)
                    .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                    .withAlphaComponent(0.33)
                v.tool = PKInkingTool(.marker, color: ui, width: max(1, coordinator.currentStrokeWidth))

            case .eraser:
                if coordinator.currentEraseMode == .object {
                    v.tool = PKEraserTool(.vector)
                } else {
                    // keep harmless tool; drawing is disabled, overlay does pixel erase
                    v.tool = PKInkingTool(.pen, color: .black, width: 1)
                }

            case .lasso:
                v.tool = PKLassoTool()

            case .shape:
                let ui = UIColor(coordinator.currentPenColor)
                    .resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                v.tool = PKInkingTool(.pen, color: ui, width: max(1, coordinator.currentStrokeWidth))
            }

            coordinator.lastToolKey = key
        }
    }

    private func toolKey(tool: ToolType, color: Color, width: CGFloat, eraseMode: EraseMode) -> String {
        switch tool {
        case .pen:    return "pen:\(UIColor(color).description):\(width)"
        case .marker: return "marker:\(UIColor(color).description):\(width)"
        case .shape:  return "shape:\(UIColor(color).description):\(width)"
        case .lasso:  return "lasso"
        case .eraser: return "eraser:\(eraseMode == .object ? "vector" : "pixel")"
        }
    }

    // MARK: - Layout helpers (your originals, lightly guarded)

    private func desiredContentHeight(_ v: PKCanvasView) -> CGFloat {
        let viewportH = max(1, v.bounds.height)
        let minH = max(minPageHeight, viewportH + 200)
        let drawingBottom = v.drawing.bounds.isEmpty ? 0 : v.drawing.bounds.maxY
        return max(minH, drawingBottom + bottomHeadroom)
    }

    private func applyInsets(_ v: PKCanvasView) {
        let safe = v.safeAreaInsets.bottom
        let writePad: CGFloat = max(60, safe)
        if v.contentInset.bottom != writePad {
            v.contentInset.bottom = writePad
        }
        let indicatorPad: CGFloat = max(2, safe + 2)
        if #available(iOS 13.0, *) {
            var vi = v.verticalScrollIndicatorInsets
            if vi.bottom != indicatorPad {
                vi.bottom = indicatorPad
                v.verticalScrollIndicatorInsets = vi
            }
        } else {
            var si = v.scrollIndicatorInsets
            if si.bottom != indicatorPad {
                si.bottom = indicatorPad
                v.scrollIndicatorInsets = si
            }
        }
    }

    private func ensureContentSize(_ v: PKCanvasView) {
        let targetH = desiredContentHeight(v)
        let w = max(1, v.bounds.width)
        if abs(v.contentSize.height - targetH) > 1 || abs(v.contentSize.width - w) > 1 {
            v.contentSize = CGSize(width: w, height: targetH)
        }
    }
}

// MARK: - KaTeX SwiftUI wrapper

struct MathLabel: UIViewRepresentable {
    var latex: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        print("MathLabel.updateUIView called with:", latex)
        
        let isDark = UITraitCollection.current.userInterfaceStyle == .dark
        let bodyStyle = isDark
            ? "background:#000; color:#fff; font-size:20px;"
            : "background:#fff; color:#000; font-size:20px;"

        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <link rel="stylesheet" href="katex.min.css">
          <script src="katex.min.js"></script>
          <script src="auto-render.min.js"></script>
        </head>
        <body style="\(bodyStyle)">
          <div id="content">
            \(latex)
          </div>
          <script>
            document.addEventListener("DOMContentLoaded", function() {
              try {
                renderMathInElement(document.getElementById("content"), {
                  delimiters: [
                    {left: "$$", right: "$$", display: true},
                    {left: "\\\\[", right: "\\\\]", display: true},
                    {left: "$", right: "$", display: false}
                  ],
                  throwOnError: false
                });
              } catch(e) {
                document.getElementById("content").innerHTML += "<p style='color:red'>KaTeX error: " + e + "</p>";
              }
            });
          </script>
        </body>
        </html>
        """

        uiView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
    }
}
// MARK: - Photos / Camera

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let vc = UIImagePickerController()
        vc.sourceType = .camera
        vc.delegate = context.coordinator
        vc.allowsEditing = false
        return vc
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let img = (info[.originalImage] as? UIImage)?.fixedOrientation()
            picker.presentingViewController?.dismiss(animated: true)
            if let i = img { parent.onImage(i) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.presentingViewController?.dismiss(animated: true)
        }
    }
}

// MARK: - Simple cropper (same as before)

struct CropperSheet: View {
    let image: UIImage
    var onCropped: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var crop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    private func fittedRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        // aspect-fit math for .scaledToFit
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        let x = (container.width  - w) / 2
        let y = (container.height - h) / 2
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func cropUIImage(_ image: UIImage, normalized r: CGRect) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)

        var px = CGRect(x: r.minX * W, y: r.minY * H,
                        width: r.width * W, height: r.height * H).integral
        let bounds = CGRect(x: 0, y: 0, width: W, height: H)
        px = px.intersection(bounds)

        guard px.width > 1, px.height > 1, let cut = cg.cropping(to: px) else { return image }
        return UIImage(cgImage: cut, scale: image.scale, orientation: image.imageOrientation)
    }


    var body: some View {
        VStack {
            Text("Crop")
                .font(.headline)
                .padding(.top)

            GeometryReader { geo in
                let fit = fittedRect(for: image.size, in: geo.size)   // where the image actually sits

                ZStack {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)

                    // draw the crop rectangle (crop is normalized 0..1)
                    let rectOnScreen = CGRect(
                        x: fit.minX + crop.minX * fit.width,
                        y: fit.minY + crop.minY * fit.height,
                        width: crop.width * fit.width,
                        height: crop.height * fit.height
                    )

                    Rectangle()
                        .path(in: rectOnScreen)
                        .stroke(Color.yellow, lineWidth: 2)
                        // simple drag to move the crop box
                        .gesture(
                            DragGesture().onChanged { v in
                                // convert drag in points -> normalized units
                                let dx = v.translation.width  / fit.width
                                let dy = v.translation.height / fit.height
                                crop.origin.x = min(max(0, crop.origin.x + dx), 1 - crop.width)
                                crop.origin.y = min(max(0, crop.origin.y + dy), 1 - crop.height)
                            }
                        )
                }
            }
            .padding()

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Crop") {
                    let cropped = cropUIImage(image, normalized: crop)
                    onCropped(cropped)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Binding var baseURL: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Base URL (e.g. http://192.168.0.42:8000)", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    Text("Simulator can use http://127.0.0.1:8000. Real iPad must use your Mac’s LAN IP.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Helpers

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct ZoomableImage: View {
    let image: Image
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .gesture(
                MagnificationGesture()
                    .onChanged { value in scale = lastScale * value }
                    .onEnded { _ in lastScale = max(1.0, min(6.0, scale)) ; scale = lastScale }
            )
            .gesture(
                DragGesture()
                    .onChanged { v in offset = CGSize(width: lastOffset.width + v.translation.width,
                                                      height: lastOffset.height + v.translation.height) }
                    .onEnded { _ in lastOffset = offset }
            )
            .scaleEffect(scale)
            .offset(offset)
            .animation(.default, value: scale)
    }
}

struct ShapeDrawOverlay: View {
    @Binding var currentShape: ShapeKind
    @Binding var dragStart: CGPoint?
    @Binding var dragRect: CGRect?
    @Binding var shapes: [ShapeItem]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // existing shapes
                ForEach(shapes) { item in
                    ShapeView(kind: item.kind, rect: item.rect)
                }
                // preview while dragging
                if let r = dragRect {
                    ShapeView(
                        kind: currentShape,
                        rect: r,
                        color: Color.blue.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 6])
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        let s = dragStart ?? value.startLocation
                        let e = value.location
                        dragRect = CGRect(x: min(s.x,e.x), y: min(s.y,e.y),
                                          width: abs(e.x - s.x), height: abs(e.y - s.y))
                    }
                    .onEnded { _ in
                        if let r = dragRect {
                            shapes.append(.init(kind: currentShape, rect: r))
                        }
                        dragStart = nil
                        dragRect = nil
                    }
            )
        }
    }
}

struct ShapeItem: Identifiable {
    var id = UUID()
    var kind: ShapeKind
    var rect: CGRect
}

struct ShapeView: View {
    let kind: ShapeKind
    let rect: CGRect
    var color: Color = .primary.opacity(0.9)
    var style: StrokeStyle = .init(lineWidth: 2, lineCap: .round, lineJoin: .round)

    var body: some View {
        Path { p in
            switch kind {
            case .rectangle:
                p.addRoundedRect(in: rect, cornerSize: .init(width: 8, height: 8))
            case .ellipse:
                p.addEllipse(in: rect)
            case .line, .arrow:
                p.move(to: rect.origin)
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                if kind == .arrow {
                    let end = CGPoint(x: rect.maxX, y: rect.maxY)
                    let v = CGVector(dx: end.x - rect.minX, dy: end.y - rect.minY)
                    let len = max(1, hypot(v.dx, v.dy))
                    let ux = v.dx / len, uy = v.dy / len
                    let tip = end
                    let back = CGPoint(x: tip.x - ux*18, y: tip.y - uy*18)
                    let left = CGPoint(x: back.x + -uy*8, y: back.y + ux*8)
                    let right = CGPoint(x: back.x - -uy*8, y: back.y - ux*8)
                    p.move(to: tip); p.addLine(to: left)
                    p.move(to: tip); p.addLine(to: right)
                }
            }
        }
        .stroke(color, style: style)
    }
}

extension UIImage {
    func fixedOrientation() -> UIImage {
        if imageOrientation == .up { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        draw(in: CGRect(origin: .zero, size: size))
        let normalized = UIGraphicsGetImageFromCurrentImageContext() ?? self
        UIGraphicsEndImageContext()
        return normalized
    }

    func withBackground(color: UIColor) -> UIImage {
        let rect = CGRect(origin: .zero, size: size)
        UIGraphicsBeginImageContextWithOptions(size, true, scale)
        color.setFill()
        UIRectFill(rect)
        draw(in: rect)
        let result = UIGraphicsGetImageFromCurrentImageContext() ?? self
        UIGraphicsEndImageContext()
        return result
    }
}

private func makeTempTexFile(text: String) -> URL? {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent("ntx-\(UUID().uuidString.prefix(8)).tex")
    do { try text.data(using: .utf8)?.write(to: url); return url } catch { return nil }
}

// MARK: - KaTeX cleaning helper
private func cleanForKaTeX(_ raw: String) -> String {
    var s = raw

    // Remove documentclass and usepackage
    s = s.replacingOccurrences(of: "\\\\documentclass\\{.*?\\}", with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\\\usepackage\\{.*?\\}", with: "", options: .regularExpression)

    // Remove begin{document} / end{document}
    s = s.replacingOccurrences(of: "\\\\begin\\{document\\}", with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: "\\\\end\\{document\\}", with: "", options: .regularExpression)

    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

private final class DrawingUndoTarget {
    let set: (PKDrawing) -> Void
    init(set: @escaping (PKDrawing) -> Void) { self.set = set }
}

enum StrokeEraserDev {
    static func runSimpleSplitTest() {
        let ink = PKInk(.pen, color: .black)

        // A straight 0→100 line
        var pts: [PKStrokePoint] = []
        for x in stride(from: 0, through: 100, by: 2) {
            let p = CGPoint(x: CGFloat(x), y: 0)
            pts.append(PKStrokePoint(location: p,
                                     timeOffset: 0,
                                     size: CGSize(width: 4, height: 4),
                                     opacity: 1, force: 1, azimuth: 0, altitude: .pi/2))
        }
        let path = PKStrokePath(controlPoints: pts, creationDate: .now)
        let s = PKStroke(ink: ink, path: path, transform: .identity)
        let drawing = PKDrawing(strokes: [s])

        // Eraser crosses at x≈50
        let eraser: [CGPoint] = [CGPoint(x: 50, y: -10), CGPoint(x: 50, y: 10)]
        let out = StrokeEraser.erase(drawing, with: eraser, radius: 6)

        print("Split test: in=\(drawing.strokes.count) out=\(out.strokes.count)") // expect 2
    }
}
