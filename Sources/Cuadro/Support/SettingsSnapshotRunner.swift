import AppKit
import CuadroKit
import SwiftUI

/// Offline UI checks, without starting Sparkle, registering shortcuts or capturing the screen.
enum SettingsSnapshotRunner {
    static func run(outputDirectory: URL) {
        Task {
            do {
                try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                try await capture(into: outputDirectory)
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("settings-snapshot failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }

    private static func capture(into directory: URL) async throws {
        SettingsWindowController.shared.show()
        guard let window = SettingsWindowController.shared.window,
              let tabs = window.contentViewController as? NSTabViewController
        else {
            throw SnapshotCheckFailure(description: "Settings window has no tab controller")
        }
        tabs.transitionOptions = []
        var offer = UpdateOffer(version: "0.6.0", currentVersion: "0.5.0")
        offer.size = 12_000_000
        offer.notes = "Improved captures and recording.\n\n- A clearer update experience\n- Native settings with no switch controls"
        let phases: [(String, UpdatePhase)] = [
            ("permission", .permission), ("checking", .checking), ("available", .available(offer)),
            ("downloading", .downloading(offer, received: 6_000_000, expected: 12_000_000)),
            ("preparing", .preparing(offer, progress: 0.7)), ("ready", .ready(offer)),
            ("installing", .installing(offer, canRetry: true)), ("up-to-date", .upToDate(currentVersion: "0.5.0")),
            ("unavailable", .unavailable(title: "A newer macOS is required", message: "This update is not compatible with this Mac.")),
            ("failed", .failed(message: "The connection was interrupted. Check your connection and try again.")),
            ("installed", .installed),
        ]
        for style in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: style)
            for index in tabs.tabViewItems.indices {
                tabs.selectedTabViewItemIndex = index
                try await snapshot(window, named: "\(style.rawValue)-\(tabs.tabViewItems[index].label)", into: directory)
            }
            for (name, phase) in phases {
                let preview = NSWindow(contentViewController: NSHostingController(rootView: SettingsPage {
                    SettingsGroup("Updates") { UpdateStatusView(phase: phase, driver: UpdateDriver()) }
                }))
                preview.isReleasedWhenClosed = false
                preview.appearance = NSAppearance(named: style)
                preview.orderFront(nil)
                try await snapshot(preview, named: "\(style.rawValue)-update-\(name)", into: directory)
                preview.close()
            }
        }
    }

    private static func snapshot(_ window: NSWindow, named name: String, into directory: URL) async throws {
        try await Task.sleep(for: .milliseconds(200))
        guard let view = window.contentView else { throw SnapshotCheckFailure(description: "No content view for \(name)") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SnapshotCheckFailure(description: "Could not render \(name)")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotCheckFailure(description: "Could not encode \(name)")
        }
        let url = directory.appendingPathComponent("\(name).png")
        try data.write(to: url)
        print("wrote \(url.path)")
    }
}
