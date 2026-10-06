import AppKit
import CuadroKit
import SwiftUI

/// Short glass notifications at the top of the active screen.
final class ToastCenter {
    static let shared = ToastCenter()

    private var panel: FloatingPanel?
    private var dismissTask: Task<Void, Never>?

    enum Style {
        case success, info, warning, failure

        var symbol: String {
            switch self {
            case .success: "checkmark.circle.fill"
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failure: "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .success: .green
            case .info: .accentColor
            case .warning: .orange
            case .failure: .red
            }
        }
    }

    func show(_ title: String, detail: String? = nil, style: Style = .success, symbol: String? = nil, swatch: RGBAColor? = nil, duration: Double = 1.8) {
        dismissTask?.cancel()
        let panel = self.panel ?? FloatingPanel(level: .aboveOverlay, clickThrough: true)
        self.panel = panel
        panel.host(ToastView(title: title, detail: detail, symbol: symbol ?? style.symbol, tint: style.tint, swatch: swatch))
        guard let screen = NSScreen.withMouse else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 12))
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        ScreenCaptureService.shared.exclude(panel)
        panel.fade(to: 1, duration: 0.15)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func showError(_ title: String, _ error: Error) {
        Log.app.error("\(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        show(title, detail: error.localizedDescription, style: .failure, duration: 3.5)
    }

    private func hide() {
        guard let panel else { return }
        panel.fade(to: 0, duration: 0.25)
        dismissTask = Task {
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            panel.orderOut(nil)
        }
    }
}

struct ToastView: View {
    let title: String
    let detail: String?
    let symbol: String
    let tint: Color
    let swatch: RGBAColor?

    var body: some View {
        HStack(spacing: 10) {
            if let swatch {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(swatch))
                    .frame(width: 18, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.7), lineWidth: 1))
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 440)
        .glassEffect(.regular, in: .capsule)
        .padding(14)
    }
}
