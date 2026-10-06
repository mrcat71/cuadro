import CuadroKit
import SwiftUI

/// Root of the editor window: edge-to-edge canvas with floating glass controls.
struct EditorView: View {
    @Bindable var model: EditorModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CanvasRepresentable(model: model)
            // Display-only status in the transparent titlebar row.
            StatusLine(model: model)
                .padding(.top, 4)
                .padding(.trailing, 10)
        }
        .ignoresSafeArea()
        .overlay {
            VStack(spacing: 0) {
                ToolPalette(model: model)
                    .padding(.top, 8)
                Spacer(minLength: 0)
                BottomBar(model: model)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .sheet(item: $model.ocrResult) { result in
            OCRResultView(result: result) { model.ocrResult = nil }
        }
        .sheet(isPresented: $model.showsResize) {
            ResizeSheet(model: model)
        }
    }
}

struct BottomBar: View {
    let model: EditorModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: 10) {
                InspectorBar(model: model)
                Spacer(minLength: 8)
                ActionBar(model: model)
            }
            VStack(alignment: .leading, spacing: 8) {
                InspectorBar(model: model)
                HStack {
                    Spacer()
                    ActionBar(model: model)
                }
            }
        }
    }
}

// MARK: Tool palette

struct ToolPalette: View {
    let model: EditorModel
    @Namespace private var selection

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(Array(EditorTool.paletteGroups.enumerated()), id: \.offset) { index, group in
                    if index > 0 {
                        Divider()
                            .frame(height: 20)
                            .padding(.horizontal, 5)
                    }
                    ForEach(group) { tool in
                        ToolButton(tool: tool, isSelected: model.tool == tool, namespace: selection) {
                            model.tool = tool
                        }
                    }
                }
            }
            .padding(5)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

struct ToolButton: View {
    let tool: EditorTool
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 14.5, weight: .medium))
                .frame(width: 34, height: 30)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(id: "selected-tool", in: namespace)
                    } else if isHovering {
                        Capsule().fill(.primary.opacity(0.08))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(tool.title)  \(String(tool.key).uppercased())")
        .animation(.snappy(duration: 0.25), value: isSelected)
        .accessibilityLabel(tool.title)
    }
}

// MARK: Status

/// Image size, zoom and the pixel under the pointer, shown in the titlebar row.
struct StatusLine: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 8) {
            if let cursor = model.cursor {
                if let color = cursor.color {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(color))
                        .frame(width: 11, height: 11)
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                    Text(color.hexString)
                        .foregroundStyle(.primary)
                }
                Text(verbatim: "\(Int(cursor.point.x)), \(Int(cursor.point.y))")
                Text("·")
            }
            let size = model.exportPixelSize
            Text(verbatim: "\(Int(size.width)) × \(Int(size.height)) px")
            Text("·")
            Text(verbatim: "\(Int((model.zoom * 100).rounded()))%")
        }
        .font(.system(size: 11, design: .monospaced))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .glassEffect(.regular, in: .capsule)
        .allowsHitTesting(false)
    }
}
