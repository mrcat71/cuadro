import AppKit
import CuadroKit
import Observation

enum ZoomCommand {
    case zoomIn, zoomOut, actualSize, fit
}

struct CursorReadout: Equatable {
    var point: CGPoint
    var color: RGBAColor?
}

/// Live ruler preview in document points.
struct RulerHover: Equatable {
    var horizontal: (CGPoint, CGPoint)?
    var vertical: (CGPoint, CGPoint)?

    static func == (lhs: RulerHover, rhs: RulerHover) -> Bool {
        lhs.horizontal?.0 == rhs.horizontal?.0 && lhs.horizontal?.1 == rhs.horizontal?.1
            && lhs.vertical?.0 == rhs.vertical?.0 && lhs.vertical?.1 == rhs.vertical?.1
    }
}

struct OCRResult: Identifiable {
    let id = UUID()
    var text: String
    var barcodes: [String]
}

enum InspectorContext: Equatable {
    case crop
    case hint(String)
    case annotation(AnnotationKind)
}

/// State and commands of one editor window.
@Observable
final class EditorModel {
    let renderer: DocumentRenderer
    let title: String
    let appName: String?

    var document = DocumentState() { didSet { canvasChanged() } }
    var tool: EditorTool = .arrow { didSet { toolChanged(from: oldValue) } }
    var obscureKind: AnnotationKind = .pixelate
    var selectedID: UUID? { didSet { if oldValue != selectedID { canvasChanged() } } }
    var editingTextID: UUID? { didSet { canvasChanged() } }
    var draft: Annotation? { didSet { canvasChanged() } }
    var cropRect: CGRect? { didSet { canvasChanged() } }
    var cropAspect: BackdropAspect = .auto
    var rulerHover: RulerHover? { didSet { if oldValue != rulerHover { canvasChanged() } } }
    var zoom: CGFloat = 1
    var cursor: CursorReadout?
    var ocrResult: OCRResult?
    var isRecognizing = false
    var showsResize = false
    var showsBackdrop = false
    private(set) var styles: [EditorTool: AnnotationStyle] = [:]

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var onCanvasChange: (() -> Void)?
    @ObservationIgnored var onZoomCommand: ((ZoomCommand) -> Void)?
    @ObservationIgnored private(set) var pixels: PixelBuffer?
    @ObservationIgnored private var previousTool: EditorTool = .arrow
    @ObservationIgnored private var textEditBefore: DocumentState?
    @ObservationIgnored private var coalescing: (key: String, time: Date)?
    @ObservationIgnored private(set) var lastSavedURL: URL?

    private let settings = AppSettings.shared

    init(result: CaptureResult) {
        renderer = DocumentRenderer(baseImage: result.image, scale: result.scale)
        appName = result.appName
        title = result.title ?? "Screenshot \(result.image.width) × \(result.image.height)"
        for tool in EditorTool.allCases {
            if let saved = settings.style(for: tool.rawValue) {
                styles[tool] = saved
            } else if let kind = tool.kind {
                var style = AnnotationStyle.defaults(for: kind)
                if kind.usesShadow { style.shadow = settings.annotationShadows }
                styles[tool] = style
            }
        }
        let image = result.image
        Task { [weak self] in
            let buffer = await Task.detached(priority: .userInitiated) { PixelBuffer(image: image) }.value
            self?.pixels = buffer
        }
    }

    var scale: CGFloat { renderer.scale }
    var imageBounds: CGRect { renderer.imageBounds }

    private func canvasChanged() {
        onCanvasChange?()
    }

    // MARK: Tools and styles

    private func toolChanged(from old: EditorTool) {
        if old == tool { return }
        if tool == .crop {
            previousTool = old
            selectedID = nil
            cropRect = document.crop ?? imageBounds
        } else if old == .crop {
            cropRect = nil
        }
        if let selected = selectedAnnotation, let kind = tool.kind, EditorTool.tool(for: selected.kind) != tool, kind != selected.kind {
            selectedID = nil
        }
        rulerHover = nil
        canvasChanged()
    }

    func style(for tool: EditorTool) -> AnnotationStyle {
        styles[tool] ?? AnnotationStyle.defaults(for: tool.kind ?? .rectangle)
    }

    func kind(for tool: EditorTool) -> AnnotationKind? {
        tool == .obscure ? obscureKind : tool.kind
    }

    var selectedAnnotation: Annotation? {
        selectedID.flatMap { document.annotation(withID: $0) }
    }

    /// Style shown in the inspector: the selection's, otherwise the tool's.
    var inspectorStyle: AnnotationStyle {
        selectedAnnotation?.style ?? style(for: tool)
    }

    var inspectorContext: InspectorContext {
        if tool == .crop { return .crop }
        if let kind = selectedAnnotation?.kind ?? kind(for: tool) { return .annotation(kind) }
        switch tool {
        case .select: return .hint("Click markup to edit it, drag to move it.")
        case .picker: return .hint("Click to copy a color.")
        default: return .hint("")
        }
    }

    /// Applies a style change to the selection (with undo) and remembers it for the tool.
    func updateStyle(_ change: (inout AnnotationStyle) -> Void) {
        if let id = selectedID, let index = document.annotations.firstIndex(where: { $0.id == id }) {
            let before = document
            change(&document.annotations[index].style)
            registerUndo(before, "Change Style", coalesceKey: "style-\(id)")
            if let tool = EditorTool.tool(for: document.annotations[index].kind) {
                var style = style(for: tool)
                change(&style)
                rememberStyle(style, for: tool)
            }
        } else {
            var style = style(for: tool)
            change(&style)
            rememberStyle(style, for: tool)
        }
    }

    func setObscureKind(_ kind: AnnotationKind) {
        obscureKind = kind
        if let id = selectedID, let index = document.annotations.firstIndex(where: { $0.id == id }),
           document.annotations[index].kind.isObscuring, document.annotations[index].kind != .erase {
            let before = document
            document.annotations[index].kind = kind
            registerUndo(before, "Change Effect")
        }
    }

    private func rememberStyle(_ style: AnnotationStyle, for tool: EditorTool) {
        styles[tool] = style
        settings.setStyle(style, for: tool.rawValue)
    }

    // MARK: Undo

    /// Registers `previous` as the undo state. Calls with the same `coalesceKey` within a short
    /// window (slider drags) collapse into one undo step.
    func registerUndo(_ previous: DocumentState, _ name: String, coalesceKey: String? = nil) {
        guard previous != document, let undoManager = window?.undoManager else { return }
        if let coalesceKey, let last = coalescing, last.key == coalesceKey, Date().timeIntervalSince(last.time) < 1 {
            coalescing = (coalesceKey, Date())
            return
        }
        coalescing = coalesceKey.map { ($0, Date()) }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.restore(previous, name)
            }
        }
        undoManager.setActionName(name)
    }

    private func restore(_ state: DocumentState, _ name: String) {
        let current = document
        coalescing = nil
        document = state
        if let id = selectedID, state.annotation(withID: id) == nil { selectedID = nil }
        registerUndo(current, name)
    }

    // MARK: Annotations

    func topAnnotation(at point: CGPoint, tolerance: CGFloat) -> Annotation? {
        document.annotations.reversed().first { $0.hitTest(point, tolerance: tolerance) }
    }

    func add(_ annotation: Annotation) {
        var annotation = annotation
        if annotation.kind == .erase {
            annotation.fillColor = fillColor(for: annotation.rect)
        }
        let before = document
        document.annotations.append(annotation)
        registerUndo(before, "Add \(annotation.kind.displayName)")
        selectedID = annotation.id
    }

    /// Mutates an annotation without registering undo (live drags).
    func mutateAnnotation(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&document.annotations[index])
    }

    /// A new step counter whose pointer tip marks `target`, with the badge beside it.
    func makeCounter(pointingAt target: CGPoint) -> Annotation {
        let style = style(for: .counter)
        var counter = Annotation(kind: .counter, start: counterBadge(pointingAt: target, style: style), end: target, style: style)
        counter.number = document.nextCounterNumber
        return counter
    }

    /// Default badge position for a step counter pointing at `target`, inside the visible image.
    func counterBadge(pointingAt target: CGPoint, style: AnnotationStyle) -> CGPoint {
        Annotation.counterBadgeCenter(
            pointingAt: target,
            radius: Annotation.counterRadius(fontSize: style.fontSize),
            within: renderer.layout(for: document).cropRect
        )
    }

    func deleteSelection() {
        guard let id = selectedID else { return }
        let before = document
        document.annotations.removeAll { $0.id == id }
        selectedID = nil
        registerUndo(before, "Delete")
    }

    func duplicateSelection() {
        guard var copy = selectedAnnotation else { return }
        copy.id = UUID()
        copy.translate(by: CGPoint(x: 12, y: 12))
        if copy.kind == .counter { copy.number = document.nextCounterNumber }
        add(copy)
    }

    func nudgeSelection(by delta: CGPoint) {
        guard let id = selectedID else { return }
        let before = document
        mutateAnnotation(id) { $0.translate(by: delta) }
        registerUndo(before, "Move", coalesceKey: "nudge-\(id)")
    }

    func reorderSelection(toFront: Bool) {
        guard let id = selectedID, let index = document.annotations.firstIndex(where: { $0.id == id }) else { return }
        let before = document
        let annotation = document.annotations.remove(at: index)
        if toFront { document.annotations.append(annotation) } else { document.annotations.insert(annotation, at: 0) }
        registerUndo(before, toFront ? "Bring to Front" : "Send to Back")
    }

    func refreshEraseFill(_ id: UUID) {
        mutateAnnotation(id) { annotation in
            if annotation.kind == .erase { annotation.fillColor = fillColor(for: annotation.rect) }
        }
    }

    func setSpotlightOpacity(_ value: Double) {
        let before = document
        document.spotlightOpacity = min(max(value, 0), 0.95)
        registerUndo(before, "Spotlight", coalesceKey: "spotlight")
    }

    // MARK: Text

    func beginNewText(at point: CGPoint) -> UUID {
        let annotation = Annotation(kind: .text, start: point, style: style(for: .text))
        textEditBefore = document
        document.annotations.append(annotation)
        selectedID = annotation.id
        editingTextID = annotation.id
        return annotation.id
    }

    func beginEditingText(_ id: UUID) {
        textEditBefore = document
        selectedID = id
        editingTextID = id
    }

    func updateEditingText(_ text: String) {
        guard let id = editingTextID else { return }
        mutateAnnotation(id) { $0.text = text }
    }

    func endEditingText(_ text: String) {
        guard let id = editingTextID else { return }
        editingTextID = nil
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.annotations.removeAll { $0.id == id }
            selectedID = nil
        } else {
            mutateAnnotation(id) { $0.text = text }
            selectedID = id
        }
        if let before = textEditBefore { registerUndo(before, "Text") }
        textEditBefore = nil
    }

    // MARK: Pixels

    func color(at point: CGPoint) -> RGBAColor? {
        guard let pixels else { return nil }
        let x = Int((point.x * scale).rounded(.down))
        let y = Int((point.y * scale).rounded(.down))
        guard pixels.contains(x: x, y: y) else { return nil }
        return pixels.color(x: x, y: y)
    }

    func fillColor(for rect: CGRect) -> RGBAColor? {
        pixels?.dominantSurroundingColor(of: PixelRect(covering: rect.scaled(by: scale)))
    }

    func updateCursor(at point: CGPoint?) {
        guard let point, imageBounds.contains(point) else {
            cursor = nil
            return
        }
        cursor = CursorReadout(point: point, color: color(at: point))
    }

    func pickColor(at point: CGPoint) {
        guard let color = color(at: point) else { return }
        let text = color.string(in: settings.colorFormat)
        Pasteboard.copy(text: text)
        ToastCenter.shared.show("Copied \(text)", swatch: color)
    }

    /// Updates the hover lines of the ruler tool.
    func updateRulerHover(at point: CGPoint?) {
        guard tool == .ruler, let point, imageBounds.contains(point), let pixels else {
            rulerHover = nil
            return
        }
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard let span = EdgeFinder.span(in: pixels, x: x, y: y, tolerance: 10) else {
            rulerHover = nil
            return
        }
        rulerHover = RulerHover(
            horizontal: (CGPoint(x: CGFloat(span.minX) / scale, y: point.y), CGPoint(x: CGFloat(span.maxX + 1) / scale, y: point.y)),
            vertical: (CGPoint(x: point.x, y: CGFloat(span.minY) / scale), CGPoint(x: point.x, y: CGFloat(span.maxY + 1) / scale))
        )
    }

    /// Turns the current hover lines into measurement annotations.
    func stampRulerHover() {
        guard let hover = rulerHover else { return }
        let before = document
        for segment in [hover.horizontal, hover.vertical].compactMap({ $0 }) {
            document.annotations.append(Annotation(kind: .measure, start: segment.0, end: segment.1, style: style(for: .ruler)))
        }
        registerUndo(before, "Add Measurement")
    }

    // MARK: Crop

    var cropAspectRatio: CGFloat? { cropAspect.ratio }

    func applyCrop() {
        guard let rect = cropRect?.snapped(toScale: scale).intersection(imageBounds), !rect.isNull, rect.width >= 1, rect.height >= 1 else {
            cancelCrop()
            return
        }
        let before = document
        document.crop = rect.equalTo(imageBounds) ? nil : rect
        registerUndo(before, "Crop")
        tool = previousTool == .crop ? .select : previousTool
    }

    func cancelCrop() {
        tool = previousTool == .crop ? .select : previousTool
    }

    func resetCrop() {
        cropRect = imageBounds
    }

    /// Shrinks the crop to the content inside uniform borders.
    func autoTrim() {
        guard let pixels else { return }
        let current = (cropRect ?? imageBounds).scaled(by: scale)
        let trimmed = pixels.trimmedContentRect(PixelRect(covering: current))
        cropRect = trimmed.cgRect.scaled(by: 1 / scale)
    }

    func setCropAspect(_ aspect: BackdropAspect) {
        cropAspect = aspect
        guard let ratio = aspect.ratio, let rect = cropRect else { return }
        var width = rect.width
        var height = rect.height
        if width / height > ratio { width = height * ratio } else { height = width / ratio }
        cropRect = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height).intersection(imageBounds)
    }

    // MARK: Backdrop and resize

    func setBackdrop(_ backdrop: Backdrop?) {
        let before = document
        document.backdrop = backdrop
        if let backdrop { settings.backdrop = backdrop }
        registerUndo(before, backdrop == nil ? "Remove Backdrop" : "Backdrop", coalesceKey: "backdrop")
    }

    func updateBackdrop(_ change: (inout Backdrop) -> Void) {
        var backdrop = document.backdrop ?? settings.backdrop
        change(&backdrop)
        setBackdrop(backdrop)
    }

    func setOutputScale(_ value: CGFloat) {
        let before = document
        document.outputScale = min(max(value, 0.05), 8)
        registerUndo(before, "Resize")
    }

    // MARK: Zoom

    func zoom(_ command: ZoomCommand) {
        onZoomCommand?(command)
    }

    // MARK: Export

    private var pixelsPerPoint: CGFloat { settings.downscaleRetina ? 1 : scale }
    private var exportScale: CGFloat { pixelsPerPoint * document.outputScale }

    func renderForExport() -> CGImage? {
        renderer.render(document, pixelsPerPoint: pixelsPerPoint)
    }

    var exportPixelSize: CGSize {
        let size = renderer.layout(for: document).canvasSize
        return CGSize(width: (size.width * exportScale).rounded(), height: (size.height * exportScale).rounded())
    }

    func copyToClipboard() {
        guard let image = renderForExport() else { return }
        if Pasteboard.copy(image: image, scale: exportScale) {
            ToastCenter.shared.show("Copied to clipboard", detail: "\(image.width) × \(image.height) px")
        }
    }

    func quickSave() {
        guard let image = renderForExport() else { return }
        do {
            let url = try SaveService.quickSave(image, scale: exportScale, appName: appName)
            lastSavedURL = url
            ToastCenter.shared.show("Saved", detail: url.lastPathComponent)
        } catch {
            ToastCenter.shared.showError("Could not save", error)
        }
    }

    func saveAs() {
        guard let image = renderForExport() else { return }
        let name = FileNameTemplate.render(
            settings.fileNameTemplate,
            context: .init(width: image.width, height: image.height, appName: appName, counter: 1)
        )
        SaveService.saveAs(image, scale: exportScale, suggestedName: name, window: window)
    }

    func revealLastSaved() {
        guard let lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastSavedURL])
    }

    func pin() {
        guard let image = renderForExport() else { return }
        PinWindowController.pin(image: image, scale: exportScale, at: nil)
    }

    func temporaryFile() -> URL? {
        guard let image = renderForExport() else { return nil }
        do {
            return try ImageExporter.temporaryFile(for: image, scale: exportScale, name: title)
        } catch {
            ToastCenter.shared.showError("Could not create a file", error)
            return nil
        }
    }

    func openInPreview() {
        guard let url = temporaryFile() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func printImage() {
        guard let image = renderForExport() else { return }
        let imageView = NSImageView(image: NSImage(cgImage: image, scale: exportScale))
        imageView.frame = NSRect(origin: .zero, size: imageView.image?.size ?? .zero)
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        let operation = NSPrintOperation(view: imageView, printInfo: info)
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    func recognizeText() {
        guard !isRecognizing, let image = renderForExport() else { return }
        isRecognizing = true
        Task {
            defer { isRecognizing = false }
            do {
                let result = try await TextRecognizer.recognize(image)
                if result.isEmpty {
                    ToastCenter.shared.show("No text found", style: .warning, symbol: "text.viewfinder")
                } else {
                    if !result.text.isEmpty { Pasteboard.copy(text: result.text) }
                    ocrResult = OCRResult(text: result.text, barcodes: result.barcodes)
                }
            } catch {
                ToastCenter.shared.showError("Text recognition failed", error)
            }
        }
    }

    /// Adds the clipboard image as a movable overlay.
    func pasteImage(at center: CGPoint? = nil) {
        guard let pasted = Pasteboard.image() else { return }
        let id = UUID()
        renderer.overlayImages[id] = pasted.image
        var size = CGSize(width: CGFloat(pasted.image.width) / pasted.scale, height: CGFloat(pasted.image.height) / pasted.scale)
        let visible = (document.crop ?? imageBounds)
        let limit = CGSize(width: visible.width * 0.8, height: visible.height * 0.8)
        let factor = min(1, limit.width / max(size.width, 1), limit.height / max(size.height, 1))
        size = CGSize(width: size.width * factor, height: size.height * factor)
        let middle = center ?? visible.center
        var annotation = Annotation(
            kind: .image,
            start: CGPoint(x: middle.x - size.width / 2, y: middle.y - size.height / 2),
            end: CGPoint(x: middle.x + size.width / 2, y: middle.y + size.height / 2),
            style: AnnotationStyle.defaults(for: .image)
        )
        annotation.imageID = id
        annotation.style.shadow = true
        add(annotation)
        tool = .select
    }
}
