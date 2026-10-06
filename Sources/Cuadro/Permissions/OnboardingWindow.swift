import AppKit
import SwiftUI

@Observable
final class PermissionStatus {
    var screenRecording = PermissionCenter.shared.screenRecordingState
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
        screenRecording = PermissionCenter.shared.screenRecordingState
        accessibility = PermissionCenter.shared.hasAccessibility
    }
}

/// Welcome window with the live state of every permission. Opens on first launch, on later launches
/// while Screen Recording is missing, and when a capture cannot run yet.
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
            PermissionCenter.shared.completeOnboarding()
            self?.close()
        })
        // Size once up front instead of letting SwiftUI resize the window during layout. Without
        // sizing options the view has no intrinsic size, so `fittingSize` would be zero: ask
        // SwiftUI for the height at the view's fixed width instead.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(hosting.sizeThatFits(in: CGSize(width: 520, height: 2000)))
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

    /// The close button and ⌘W. Quitting closes the window without asking, so it is not taken as
    /// the user having seen the permissions.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        PermissionCenter.shared.completeOnboarding()
        return true
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
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Welcome to Cuadro")
                    .font(.system(size: 26, weight: .bold))
                Text("Cuadro needs to see your screen to take screenshots. Everything stays on your Mac.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PermissionList(status: status)
            // Every hint takes part in layout, so the window (sized once) fits whichever one shows.
            ZStack {
                ForEach(PermissionState.allCases, id: \.self) { state in
                    Text(Self.hint(for: state))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(state == status.screenRecording ? 1 : 0)
                        .accessibilityHidden(state != status.screenRecording)
                }
            }
            HStack {
                if status.screenRecording == .needsRelaunch {
                    Button("Relaunch Cuadro", action: PermissionCenter.shared.relaunch)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else if status.screenRecording == .missing {
                    Button("Relaunch Cuadro", action: PermissionCenter.shared.relaunch)
                        .buttonStyle(.glass)
                }
                Spacer()
                if status.screenRecording == .granted {
                    Button("Done", action: close)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Later", action: close)
                        .buttonStyle(.glass)
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 36)
        .padding(.bottom, 24)
        .frame(width: 520)
    }

    private static func hint(for screenRecording: PermissionState) -> String {
        switch screenRecording {
        case .granted:
            "Cuadro Settings > About shows these at any time."
        case .needsRelaunch:
            "Screen Recording is on. Relaunch Cuadro so macOS applies it."
        case .missing:
            "Switch Cuadro on in System Settings, then relaunch it. Already on but captures fail? Remove Cuadro from the list with −, then allow it again."
        }
    }
}

/// Live state of each permission Cuadro uses, with a button for each missing one.
struct PermissionList: View {
    let status: PermissionStatus

    var body: some View {
        VStack(spacing: 0) {
            PermissionRow(title: "Screen Recording", detail: "Required for every capture.", state: status.screenRecording) {
                let permissions = PermissionCenter.shared
                if !permissions.requestScreenRecording() {
                    permissions.openScreenRecordingSettings()
                }
            }
            Divider().padding(.horizontal, 14)
            PermissionRow(
                title: "Accessibility",
                detail: "Optional, only for auto-scroll in scrolling captures.",
                state: status.accessibility ? .granted : .missing
            ) {
                PermissionCenter.shared.requestAccessibility()
                PermissionCenter.shared.openAccessibilitySettings()
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let state: PermissionState
    let allow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .granted:
                Text("Allowed").foregroundStyle(.secondary)
            case .needsRelaunch:
                Text("Relaunch to apply").foregroundStyle(.orange)
            case .missing:
                Button("Allow…", action: allow)
                    .accessibilityLabel("Allow \(title)")
            }
        }
        .padding(14)
    }

    private var symbol: String {
        switch state {
        case .granted: "checkmark.circle.fill"
        case .needsRelaunch: "arrow.clockwise.circle.fill"
        case .missing: "circle.dashed"
        }
    }

    private var tint: Color {
        switch state {
        case .granted: .green
        case .needsRelaunch: .orange
        case .missing: .secondary
        }
    }
}
