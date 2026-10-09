import AppKit
import CuadroKit
import SwiftUI

final class EditorWindow: NSWindow {}

/// One editor window per capture. Also the responder for the main menu's editor commands.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private static var openControllers: [EditorWindowController] = []

    let model: EditorModel

    static func open(_ result: CaptureResult) {
        let controller = EditorWindowController(result: result)
        openControllers.append(controller)
        controller.present(near: result.screenRect)
    }

    static var hasOpenWindows: Bool { !openControllers.isEmpty }

    private init(result: CaptureResult) {
        model = EditorModel(result: result)
        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = model.title
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 640, height: 440)
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingController(rootView: EditorView(model: model))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        model.window = window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func present(near screenRect: CGRect?) {
        guard let window else { return }
        let screen = screenRect.flatMap { rect in NSScreen.screens.first { $0.frame.intersects(rect) } } ?? NSScreen.withMouse
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let canvas = model.renderer.imageSize
        var size = CGSize(width: canvas.width + 64, height: canvas.height + 196)
        // Wide enough for the inspector and action bar to share one row.
        size.width = min(max(size.width, 980), visible.width * 0.92)
        size.height = min(max(size.height, 540), visible.height * 0.92)
        window.setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height),
            display: false
        )
        DockPresence.shared.track(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Drawn before the selection overlay above it goes away, so nothing flashes in between.
        window.displayIfNeeded()
    }

    private var canvas: CanvasView? {
        (window?.contentView.flatMap { Self.find(CanvasView.self, in: $0) })
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        canvas?.finishEditing()
        Self.openControllers.removeAll { $0 === self }
    }

    // MARK: Menu commands

    @objc func copy(_ sender: Any?) {
        canvas?.finishEditing()
        model.copyToClipboard()
    }

    @objc func undo(_ sender: Any?) { window?.undoManager?.undo() }
    @objc func redo(_ sender: Any?) { window?.undoManager?.redo() }
    @objc func paste(_ sender: Any?) { model.pasteImage() }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }
    @objc func duplicate(_ sender: Any?) { model.duplicateSelection() }

    @objc func saveImage(_ sender: Any?) {
        canvas?.finishEditing()
        model.quickSave()
    }

    @objc func saveImageAs(_ sender: Any?) {
        canvas?.finishEditing()
        model.saveAs()
    }

    @objc func printImage(_ sender: Any?) { model.printImage() }
    @objc func zoomInCanvas(_ sender: Any?) { model.zoom(.zoomIn) }
    @objc func zoomOutCanvas(_ sender: Any?) { model.zoom(.zoomOut) }
    @objc func zoomActualSize(_ sender: Any?) { model.zoom(.actualSize) }
    @objc func zoomToFit(_ sender: Any?) { model.zoom(.fit) }
    @objc func pinImage(_ sender: Any?) { model.pin() }
    @objc func recognizeTextInImage(_ sender: Any?) { model.recognizeText() }
    @objc func toggleBackdrop(_ sender: Any?) { model.showsBackdrop.toggle() }
    @objc func resizeImage(_ sender: Any?) { model.showsResize = true }
    @objc func openInPreview(_ sender: Any?) { model.openInPreview() }

    @objc func selectEditorTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let tool = EditorTool(rawValue: raw) else { return }
        model.tool = tool
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            let manager = window?.undoManager
            menuItem.title = manager?.undoMenuItemTitle ?? "Undo"
            return manager?.canUndo ?? false
        case #selector(redo(_:)):
            let manager = window?.undoManager
            menuItem.title = manager?.redoMenuItemTitle ?? "Redo"
            return manager?.canRedo ?? false
        case #selector(delete(_:)), #selector(duplicate(_:)):
            return model.selectedID != nil
        case #selector(paste(_:)):
            return Pasteboard.hasImage
        case #selector(selectEditorTool(_:)):
            menuItem.state = (menuItem.representedObject as? String) == model.tool.rawValue ? .on : .off
            return true
        default:
            return true
        }
    }
}
