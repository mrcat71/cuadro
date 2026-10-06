import AppKit
import CuadroKit
import SwiftUI

/// macOS-style floating thumbnails in the bottom-right corner after a capture.
final class ThumbnailOverlay {
    static let shared = ThumbnailOverlay()

    private var items: [ThumbnailItem] = []

    func show(_ result: CaptureResult) {
        let item = ThumbnailItem(result: result) { [weak self] item in
            self?.remove(item)
        }
        items.insert(item, at: 0)
        if items.count > 5, let oldest = items.last {
            remove(oldest)
        }
        layout()
        item.present()
    }

    private func remove(_ item: ThumbnailItem) {
        item.dismiss()
        items.removeAll { $0 === item }
        layout()
    }

    private func layout() {
        guard let screen = NSScreen.withMouse else { return }
        let visible = screen.visibleFrame
        var y = visible.minY + 12
        for item in items {
            let size = item.panel.frame.size
            item.panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 12, y: y))
            y += size.height - 8
        }
    }
}

final class ThumbnailItem {
    let result: CaptureResult
    let panel = FloatingPanel(level: .statusBar)
    private let onClose: (ThumbnailItem) -> Void
    private var dismissTask: Task<Void, Never>?

    init(result: CaptureResult, onClose: @escaping (ThumbnailItem) -> Void) {
        self.result = result
        self.onClose = onClose
        panel.host(ThumbnailCard(
            image: NSImage(cgImage: result.image, scale: result.scale),
            onHover: { [weak self] hovering in self?.hoverChanged(hovering) },
            onAction: { [weak self] action in self?.perform(action) },
            fileProvider: { [weak self] in self?.temporaryFile() }
        ))
    }

    func present() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        ScreenCaptureService.shared.exclude(panel)
        panel.fade(to: 1, duration: 0.2)
        scheduleDismiss()
    }

    func dismiss() {
        dismissTask?.cancel()
        panel.orderOut(nil)
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        let seconds = AppSettings.shared.thumbnailSeconds
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.onClose(self)
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        if hovering { dismissTask?.cancel() } else { scheduleDismiss() }
    }

    private func temporaryFile() -> URL? {
        try? ImageExporter.temporaryFile(for: result.image, scale: result.scale, name: result.title ?? "Screenshot")
    }

    private func perform(_ action: ThumbnailCard.Action) {
        switch action {
        case .edit:
            EditorWindowController.open(result)
        case .copy:
            if Pasteboard.copy(image: result.image, scale: result.scale) { ToastCenter.shared.show("Copied to clipboard") }
        case .save:
            do {
                let url = try SaveService.quickSave(result.image, scale: result.scale, appName: result.appName)
                ToastCenter.shared.show("Saved", detail: url.lastPathComponent)
            } catch {
                ToastCenter.shared.showError("Could not save", error)
            }
        case .pin:
            PinWindowController.pin(image: result.image, scale: result.scale, at: nil)
        case .close:
            break
        }
        onClose(self)
    }
}

struct ThumbnailCard: View {
    enum Action { case edit, copy, save, pin, close }

    let image: NSImage
    let onHover: (Bool) -> Void
    let onAction: (Action) -> Void
    let fileProvider: () -> URL?
    @State private var isHovering = false

    private var displaySize: CGSize {
        let size = image.size
        let factor = min(220 / max(size.width, 1), 150 / max(size.height, 1), 1)
        return CGSize(width: max(size.width * factor, 80), height: max(size.height * factor, 50))
    }

    var body: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: displaySize.width, height: displaySize.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onDrag {
                    guard let url = fileProvider() else { return NSItemProvider() }
                    return NSItemProvider(contentsOf: url) ?? NSItemProvider()
                }
                .onTapGesture { onAction(.edit) }
            if isHovering {
                VStack {
                    HStack {
                        Button { onAction(.close) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: .circle)
                        Spacer()
                    }
                    Spacer()
                    HStack(spacing: 2) {
                        action("doc.on.doc", "Copy", .copy)
                        action("square.and.arrow.down", "Save", .save)
                        action("pencil", "Edit", .edit)
                        action("pin", "Pin", .pin)
                    }
                    .padding(3)
                    .glassEffect(.regular, in: .capsule)
                }
                .padding(6)
                .transition(.opacity)
            }
        }
        .padding(6)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(10)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
            onHover(hovering)
        }
    }

    private func action(_ symbol: String, _ help: String, _ action: Action) -> some View {
        Button { onAction(action) } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
