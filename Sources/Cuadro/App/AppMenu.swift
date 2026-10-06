import AppKit

/// Main menu, visible while an editor or settings window is open.
enum AppMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Cuadro", appItems()))
        main.addItem(submenu("File", fileItems()))
        main.addItem(submenu("Edit", editItems()))
        main.addItem(submenu("Image", imageItems()))
        main.addItem(submenu("View", viewItems()))
        let window = submenu("Window", windowItems())
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        let help = submenu("Help", [item("Cuadro on GitHub", #selector(AppDelegate.showHelp(_:)))])
        main.addItem(help)
        NSApp.helpMenu = help.submenu
        return main
    }

    private static func appItems() -> [NSMenuItem] {
        [
            item("About Cuadro", #selector(AppDelegate.showAbout(_:))),
            .separator(),
            item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator(),
            item("Hide Cuadro", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Cuadro", #selector(NSApplication.terminate(_:)), "q"),
        ]
    }

    private static func fileItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for action in [AppAction.captureArea, .captureWindow, .captureFullscreen, .captureScrolling, .recognizeText] {
            let entry = item(action.title, #selector(AppDelegate.performAppAction(_:)))
            entry.representedObject = action.rawValue
            items.append(entry)
        }
        items += [
            .separator(),
            item("Open Image…", #selector(AppDelegate.openImageFile(_:)), "o", [.command, .shift]),
            item("Open from Clipboard", #selector(AppDelegate.openFromClipboard(_:)), "v", [.command, .shift]),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save", #selector(EditorWindowController.saveImage(_:)), "s"),
            item("Save As…", #selector(EditorWindowController.saveImageAs(_:)), "s", [.command, .shift]),
            .separator(),
            item("Print…", #selector(EditorWindowController.printImage(_:)), "p"),
        ]
        return items
    }

    private static func editItems() -> [NSMenuItem] {
        [
            item("Undo", #selector(EditorWindowController.undo(_:)), "z"),
            item("Redo", #selector(EditorWindowController.redo(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Duplicate", #selector(EditorWindowController.duplicate(_:)), "d"),
        ]
    }

    private static func imageItems() -> [NSMenuItem] {
        let tools = NSMenuItem(title: "Tools", action: nil, keyEquivalent: "")
        let toolMenu = NSMenu(title: "Tools")
        for tool in EditorTool.allCases {
            let entry = item("\(tool.title)    \(String(tool.key).uppercased())", #selector(EditorWindowController.selectEditorTool(_:)))
            entry.representedObject = tool.rawValue
            entry.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            toolMenu.addItem(entry)
        }
        tools.submenu = toolMenu
        return [
            tools,
            .separator(),
            item("Backdrop…", #selector(EditorWindowController.toggleBackdrop(_:)), "b", [.command, .shift]),
            item("Resize…", #selector(EditorWindowController.resizeImage(_:)), "r", [.command, .option]),
            item("Recognize Text", #selector(EditorWindowController.recognizeTextInImage(_:)), "t", [.command, .shift]),
            item("Pin to Screen", #selector(EditorWindowController.pinImage(_:)), "p", [.command, .shift]),
            item("Open in Preview", #selector(EditorWindowController.openInPreview(_:))),
        ]
    }

    private static func viewItems() -> [NSMenuItem] {
        [
            item("Zoom In", #selector(EditorWindowController.zoomInCanvas(_:)), "="),
            item("Zoom Out", #selector(EditorWindowController.zoomOutCanvas(_:)), "-"),
            item("Actual Size", #selector(EditorWindowController.zoomActualSize(_:)), "0"),
            item("Zoom to Fit", #selector(EditorWindowController.zoomToFit(_:)), "9"),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ]
    }

    private static func windowItems() -> [NSMenuItem] {
        [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ]
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for entry in items { menu.addItem(entry) }
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }
}
