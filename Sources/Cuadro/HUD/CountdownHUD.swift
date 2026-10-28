import AppKit
import SwiftUI

@Observable
final class CountdownModel {
    var remaining: Int

    init(remaining: Int) {
        self.remaining = remaining
    }
}

/// Big glass countdown for delayed captures (`shared`) and before a screen recording starts (an
/// instance of its own, so the delayed capture shortcut cannot cancel it).
final class CountdownHUD {
    static let shared = CountdownHUD()

    private var panel: FloatingPanel?
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// - Parameter center: Cocoa global; the middle of the screen with the pointer if nil.
    func start(seconds: Int, at center: CGPoint? = nil, completion: @escaping () -> Void) {
        cancel()
        let model = CountdownModel(remaining: seconds)
        let panel = FloatingPanel(level: .aboveOverlay, clickThrough: true)
        panel.host(CountdownView(model: model))
        if let middle = center ?? NSScreen.withMouse.map({ CGPoint(x: $0.frame.midX, y: $0.frame.midY) }) {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: middle.x - size.width / 2, y: middle.y - size.height / 2))
        }
        panel.orderFrontRegardless()
        ScreenCaptureService.shared.exclude(panel)
        self.panel = panel

        task = Task { [weak self] in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                model.remaining = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            panel.orderOut(nil)
            // Give the window server a moment to remove the panel before freezing the screen.
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            self?.task = nil
            self?.panel = nil
            completion()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct CountdownView: View {
    let model: CountdownModel

    var body: some View {
        Text("\(model.remaining)")
            .font(.system(size: 64, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            .animation(.snappy, value: model.remaining)
            .frame(width: 132, height: 132)
            .glassEffect(.regular, in: .circle)
            .padding(20)
    }
}
