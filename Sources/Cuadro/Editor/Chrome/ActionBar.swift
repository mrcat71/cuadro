import AppKit
import CuadroKit
import SwiftUI

/// Output actions: backdrop, OCR, pin, share, drag-out, copy and save.
struct ActionBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Zoom In") { model.zoom(.zoomIn) }
                Button("Zoom Out") { model.zoom(.zoomOut) }
                Divider()
                Button("Zoom to Fit") { model.zoom(.fit) }
                Button("Actual Size") { model.zoom(.actualSize) }
            } label: {
                Text(verbatim: "\(Int((model.zoom * 100).rounded()))%")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 42, minHeight: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Zoom")
            Divider()
                .frame(height: 20)
                .padding(.horizontal, 2)
            BarButton(symbol: "photo.artframe", help: "Backdrop", isOn: model.document.backdrop != nil) {
                model.showsBackdrop.toggle()
            }
            .popover(isPresented: $model.showsBackdrop, arrowEdge: .top) {
                BackdropPanel(model: model)
            }
            BarButton(symbol: model.isRecognizing ? "ellipsis" : "text.viewfinder", help: "Recognize Text  ⇧⌘T") {
                model.recognizeText()
            }
            BarButton(symbol: "pin", help: "Pin to Screen  ⇧⌘P") {
                model.pin()
            }
            ShareButton(model: model)
                .frame(width: 32, height: 30)
                .help("Share")
            DragHandle(model: model)
            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)
            BarButton(symbol: "doc.on.doc", help: "Copy  ⌘C") {
                model.copyToClipboard()
            }
            BarButton(symbol: "square.and.arrow.down", help: "Save  ⌘S") {
                model.quickSave()
            }
            Menu {
                Button("Save As…") { model.saveAs() }
                Button("Show Last Saved in Finder") { model.revealLastSaved() }
                    .disabled(model.lastSavedURL == nil)
                Divider()
                Button("Resize…") { model.showsResize = true }
                Button("Open in Preview") { model.openInPreview() }
                Button("Print…") { model.printImage() }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("More")
        }
        .padding(5)
        .glassEffect(.regular, in: .capsule)
    }
}

struct BarButton: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14.5, weight: .medium))
                .frame(width: 32, height: 30)
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .background(isHovering ? Color.primary.opacity(0.08) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Thumbnail you can drag into Finder, Mail, Slack and other apps.
struct DragHandle: View {
    let model: EditorModel

    var body: some View {
        Image(systemName: "hand.draw")
            .font(.system(size: 14.5, weight: .medium))
            .frame(width: 32, height: 30)
            .contentShape(Rectangle())
            .onDrag {
                guard let url = model.temporaryFile() else { return NSItemProvider() }
                return NSItemProvider(contentsOf: url) ?? NSItemProvider()
            }
            .help("Drag the image out")
            .accessibilityLabel("Drag the image")
    }
}

/// AppKit share picker anchored to its own button.
struct ShareButton: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!, target: context.coordinator, action: #selector(Coordinator.share(_:)))
        button.isBordered = false
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .medium)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.model = model
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    final class Coordinator: NSObject {
        var model: EditorModel

        init(model: EditorModel) {
            self.model = model
        }

        @objc func share(_ sender: NSButton) {
            guard let url = model.temporaryFile() else { return }
            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}
