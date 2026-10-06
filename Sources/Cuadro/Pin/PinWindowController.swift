import AppKit
import CuadroKit
import SwiftUI

/// A screenshot pinned as a floating, always-on-top borderless window.
final class PinWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var pins: [PinWindowController] = []

    let image: CGImage
    let scale: CGFloat
    let number: Int

    var isLocked: Bool { window?.ignoresMouseEvents ?? false }

    /// Pins `image`; `screenRect` (Cocoa global) keeps it exactly where it was captured.
    static func pin(image: CGImage, scale: CGFloat, at screenRect: CGRect?) {
        let controller = PinWindowController(image: image, scale: scale, frame: screenRect, number: (pins.map(\.number).max() ?? 0) + 1)
        pins.append(controller)
        controller.window?.orderFrontRegardless()
        controller.window?.makeKey()
        controller.window?.makeFirstResponder(controller.window?.contentView)
    }

    static func closeAll() {
        for pin in pins { pin.close() }
    }

    private init(image: CGImage, scale: CGFloat, frame: CGRect?, number: Int) {
        self.image = image
        self.scale = scale
        self.number = number
        let panel = FloatingPanel(level: .floating, allowsKey: true)
        panel.hasShadow = true
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        var rect: CGRect
        if let frame {
            rect = frame
        } else {
            let visible = NSScreen.withMouse?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let factor = min(1, visible.width * 0.6 / size.width, visible.height * 0.6 / size.height)
            let fitted = CGSize(width: size.width * factor, height: size.height * factor)
            rect = CGRect(x: visible.midX - fitted.width / 2, y: visible.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
        }
        panel.setFrame(rect, display: false)
        super.init(window: panel)
        panel.delegate = self
        let view = PinView(controller: self)
        panel.contentView = view
        panel.initialFirstResponder = view
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func windowWillClose(_ notification: Notification) {
        Self.pins.removeAll { $0 === self }
    }

    var title: String { "Pin \(number)  \(image.width) × \(image.height)" }

    func setLocked(_ locked: Bool) {
        window?.ignoresMouseEvents = locked
        if locked {
            ToastCenter.shared.show("Pin locked", detail: "Clicks pass through. Unlock it from the menu bar.", style: .info, symbol: "lock.fill")
        }
    }

    func setOpacity(_ value: CGFloat) {
        window?.alphaValue = min(max(value, 0.15), 1)
    }

    func copyImage() {
        if Pasteboard.copy(image: image, scale: scale) {
            ToastCenter.shared.show("Copied to clipboard")
        }
    }

    func edit() {
        EditorWindowController.open(CaptureResult(image: image, scale: scale, kind: .file, screenRect: window?.frame, title: title))
    }

    /// Resizes keeping the aspect ratio and the point under the pointer in place.
    func resize(by factor: CGFloat, around point: CGPoint) {
        guard let window else { return }
        let frame = window.frame
        let aspect = frame.width / max(frame.height, 1)
        let width = min(max(frame.width * factor, 48), 12_000)
        let height = width / aspect
        let rx = (point.x - frame.minX) / frame.width
        let ry = (point.y - frame.minY) / frame.height
        window.setFrame(NSRect(x: point.x - rx * width, y: point.y - ry * height, width: width, height: height), display: true)
    }

    func resetSize() {
        guard let window else { return }
        let frame = window.frame
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        window.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width, height: size.height), display: true)
    }
}

final class PinView: NSView {
    private weak var controller: PinWindowController?
    private let imageLayer = CALayer()
    private let controls: NSHostingView<PinControls>
    private let controlsSize: CGSize
    private var trackingArea: NSTrackingArea?

    init(controller: PinWindowController) {
        self.controller = controller
        controls = NSHostingView(rootView: PinControls(controller: controller))
        controlsSize = controls.fittingSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.2).cgColor
        imageLayer.contents = controller.image
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        layer?.addSublayer(imageLayer)
        controls.isHidden = true
        addSubview(controls)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        controls.frame = CGRect(
            x: bounds.maxX - controlsSize.width - 4, y: bounds.maxY - controlsSize.height - 4,
            width: controlsSize.width, height: controlsSize.height
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        controls.isHidden = bounds.width < 150 || bounds.height < 60
    }

    override func mouseExited(with event: NSEvent) {
        controls.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            controller?.resetSize()
            return
        }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let controller, let window else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 6
        if event.modifierFlags.contains(.option) {
            controller.setOpacity(window.alphaValue + delta * 0.005)
        } else {
            controller.resize(by: pow(1.006, delta), around: NSEvent.mouseLocation)
        }
    }

    override func magnify(with event: NSEvent) {
        controller?.resize(by: 1 + event.magnification, around: NSEvent.mouseLocation)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            controller?.close()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            controller?.copyImage()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "w" {
            controller?.close()
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        let menu = NSMenu()
        menu.addItem(NSMenuItem.action("Copy") { controller.copyImage() })
        menu.addItem(NSMenuItem.action("Edit") { controller.edit() })
        menu.addItem(NSMenuItem.action("Save to Screenshots Folder") {
            do {
                let url = try SaveService.quickSave(controller.image, scale: controller.scale)
                ToastCenter.shared.show("Saved", detail: url.lastPathComponent)
            } catch {
                ToastCenter.shared.showError("Could not save", error)
            }
        })
        menu.addItem(.separator())
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        for value in [1.0, 0.75, 0.5, 0.25] {
            let item = NSMenuItem.action("\(Int(value * 100))%") { controller.setOpacity(value) }
            item.state = abs((controller.window?.alphaValue ?? 1) - value) < 0.05 ? .on : .off
            opacityMenu.addItem(item)
        }
        opacity.submenu = opacityMenu
        menu.addItem(opacity)
        menu.addItem(NSMenuItem.action("Actual Size") { controller.resetSize() })
        menu.addItem(NSMenuItem.action("Lock (Click Through)") { controller.setLocked(true) })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.action("Close") { controller.close() })
        return menu
    }
}

struct PinControls: View {
    let controller: PinWindowController

    var body: some View {
        HStack(spacing: 2) {
            button("doc.on.doc", "Copy") { controller.copyImage() }
            button("pencil", "Edit") { controller.edit() }
            button("lock", "Lock (click through)") { controller.setLocked(true) }
            button("xmark", "Close") { controller.close() }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .padding(4)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Target object that runs a closure for a menu item.
final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_ sender: Any?) { handler() }
}

extension NSMenuItem {
    /// Menu item that runs `handler`; the item keeps its target alive.
    static func action(_ title: String, keyEquivalent: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuActionTarget(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.run(_:)), keyEquivalent: keyEquivalent)
        item.target = target
        item.representedObject = target
        return item
    }
}
