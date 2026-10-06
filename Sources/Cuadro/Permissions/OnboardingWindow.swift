import AppKit
import SwiftUI

@Observable
final class PermissionStatus {
    var screenRecording = PermissionCenter.shared.hasScreenRecording
    var accessibility = PermissionCenter.shared.hasAccessibility

    @ObservationIgnored private var timer: Timer?

    func startPolling() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        screenRecording = PermissionCenter.shared.hasScreenRecording
        accessibility = PermissionCenter.shared.hasAccessibility
    }
}

/// First-run window that walks through the Screen Recording permission.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private let status = PermissionStatus()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Welcome to Cuadro"
        super.init(window: window)
        let hosting = NSHostingController(rootView: OnboardingView(status: status) { [weak self] in
            self?.close()
        })
        // Size once up front instead of letting SwiftUI resize the window during layout.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        status.startPolling()
        DockPresence.shared.track(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        status.stopPolling()
    }
}

struct OnboardingView: View {
    let status: PermissionStatus
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 92, height: 92)
            VStack(spacing: 6) {
                Text("Welcome to Cuadro")
                    .font(.system(size: 26, weight: .bold))
                Text("Cuadro needs to see your screen to take screenshots. Everything stays on your Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                PermissionRow(
                    title: "Screen Recording",
                    detail: "Required for every capture.",
                    granted: status.screenRecording,
                    actionTitle: "Allow…"
                ) {
                    if !PermissionCenter.shared.requestScreenRecording() {
                        PermissionCenter.shared.openScreenRecordingSettings()
                    }
                }
                Divider().padding(.horizontal, 14)
                PermissionRow(
                    title: "Accessibility",
                    detail: "Optional, only for auto-scroll in scrolling captures.",
                    granted: status.accessibility,
                    actionTitle: "Allow…"
                ) {
                    PermissionCenter.shared.requestAccessibility()
                    PermissionCenter.shared.openAccessibilitySettings()
                }
            }
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            Text("After switching Screen Recording on in System Settings, relaunch Cuadro so macOS applies it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Relaunch Cuadro") { PermissionCenter.shared.relaunch() }
                    .buttonStyle(.glass)
                Spacer()
                Button("Done", action: close)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 520)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 20))
                .foregroundStyle(granted ? .green : .secondary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button(actionTitle, action: action)
            }
        }
        .padding(14)
    }
}
