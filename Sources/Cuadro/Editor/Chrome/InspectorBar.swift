import CuadroKit
import SwiftUI

/// Contextual style controls for the current tool or selected markup.
struct InspectorBar: View {
    let model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            switch model.inspectorContext {
            case .crop:
                CropControls(model: model)
            case .hint(let text):
                if !text.isEmpty {
                    Text(text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            case .annotation(let kind):
                AnnotationControls(model: model, kind: kind, style: model.inspectorStyle)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
    }
}

private struct AnnotationControls: View {
    let model: EditorModel
    let kind: AnnotationKind
    let style: AnnotationStyle

    var body: some View {
        if kind.usesColor {
            ColorSwatches(selected: style.color) { color in
                model.updateStyle { $0.color = color }
            }
            Divider().frame(height: 18)
        }
        if kind.usesLineWidth {
            ValueMenu(symbol: "lineweight", value: style.lineWidth, options: [1, 2, 3, 4, 6, 8, 12, 16], suffix: "pt", help: "Stroke width") { width in
                model.updateStyle { $0.lineWidth = width }
            }
        }
        switch kind {
        case .rectangle, .ellipse:
            SymbolPicker(
                selection: style.fill,
                options: [(.none, "square", "Outline"), (.translucent, "square.lefthalf.filled", "Translucent fill"), (.solid, "square.fill", "Solid fill")]
            ) { fill in model.updateStyle { $0.fill = fill } }
            if kind == .rectangle {
                ValueMenu(symbol: "square.dashed", value: style.cornerRadius, options: [0, 4, 6, 10, 16, 24], suffix: "", help: "Corner radius") { radius in
                    model.updateStyle { $0.cornerRadius = radius }
                }
            }
            dashedToggle
        case .line:
            dashedToggle
        case .arrow:
            SymbolPicker(
                selection: style.arrowHeads,
                options: [(.end, "arrow.right", "One head"), (.both, "arrow.left.and.right", "Two heads")]
            ) { heads in model.updateStyle { $0.arrowHeads = heads } }
        case .text:
            SymbolPicker(
                selection: style.textStyle,
                options: [(.plain, "textformat", "Plain"), (.outline, "character.textbox", "Outlined"), (.pill, "capsule.fill", "Label")]
            ) { textStyle in model.updateStyle { $0.textStyle = textStyle } }
            ValueMenu(symbol: "textformat.size", value: style.fontSize, options: [12, 14, 16, 18, 20, 24, 32, 40, 56, 72], suffix: "pt", help: "Font size") { size in
                model.updateStyle { $0.fontSize = size }
            }
        case .counter:
            ValueMenu(symbol: "circle.circle", value: style.fontSize, options: [12, 14, 18, 22, 28, 36], suffix: "", help: "Size") { size in
                model.updateStyle { $0.fontSize = size }
            }
        case .pixelate, .blur:
            SymbolPicker(
                selection: kind,
                options: [(.pixelate, "checkerboard.rectangle", "Pixelate"), (.blur, "drop", "Blur")]
            ) { newKind in model.setObscureKind(newKind) }
            if kind == .pixelate {
                LabeledSlider(symbol: "square.grid.3x3", value: style.pixelSize, range: 4...40, help: "Block size") { value in
                    model.updateStyle { $0.pixelSize = value }
                }
            } else {
                LabeledSlider(symbol: "aqi.medium", value: style.blurRadius, range: 2...40, help: "Blur radius") { value in
                    model.updateStyle { $0.blurRadius = value }
                }
            }
        case .spotlight:
            SymbolPicker(
                selection: style.spotlightShape,
                options: [(.rectangle, "rectangle", "Rectangle"), (.ellipse, "circle", "Ellipse")]
            ) { shape in model.updateStyle { $0.spotlightShape = shape } }
            LabeledSlider(symbol: "circle.lefthalf.filled", value: model.document.spotlightOpacity, range: 0.1...0.95, help: "Darkness (keys 1 to 9)") { value in
                model.setSpotlightOpacity(value)
            }
        case .magnifier:
            ValueMenu(symbol: "plus.magnifyingglass", value: style.magnification, options: [1.5, 2, 3, 4, 6], suffix: "×", help: "Zoom") { zoom in
                model.updateStyle { $0.magnification = zoom }
            }
        case .erase:
            Text("Fills the area with the surrounding color")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .highlighter, .pen, .measure, .image:
            EmptyView()
        }
        if kind.usesShadow {
            Toggle(isOn: Binding(get: { style.shadow }, set: { value in model.updateStyle { $0.shadow = value } })) {
                Image(systemName: "shadow")
                    .accessibilityLabel("Shadow")
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .foregroundStyle(style.shadow ? Color.accentColor : .secondary)
            .help(style.shadow ? "Drop shadow on; click to remove it" : "Drop shadow off; click to add it")
        }
        if model.selectedID != nil {
            Divider().frame(height: 18)
            Button {
                model.deleteSelection()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("Delete  ⌫")
        }
    }

    private var dashedToggle: some View {
        Toggle(isOn: Binding(get: { style.dashed }, set: { value in model.updateStyle { $0.dashed = value } })) {
            Image(systemName: "line.3.horizontal.decrease")
        }
        .toggleStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(style.dashed ? Color.accentColor : .secondary)
        .help("Dashed")
    }
}

/// Palette swatches plus a button for the system color panel.
struct ColorSwatches: View {
    let selected: RGBAColor
    let onSelect: (RGBAColor) -> Void

    private var isCustom: Bool {
        !RGBAColor.palette.contains { $0.hexString == selected.hexString }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RGBAColor.palette, id: \.self) { color in
                Button {
                    onSelect(color)
                } label: {
                    SwatchDot(fill: AnyShapeStyle(Color(color)), isSelected: color.hexString == selected.hexString)
                }
                .buttonStyle(.plain)
                .help(color.hexString)
            }
            CustomColorButton(color: selected, isSelected: isCustom, onSelect: onSelect)
        }
    }
}

struct SwatchDot: View {
    let fill: AnyShapeStyle
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 0.5))
            .padding(3)
            .overlay(Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Circle())
    }
}

/// Rainbow dot that opens the system color panel.
struct CustomColorButton: View {
    let color: RGBAColor
    let isSelected: Bool
    var supportsOpacity = true
    let onSelect: (RGBAColor) -> Void

    var body: some View {
        Button {
            ColorPanelBridge.shared.open(initial: color, showsAlpha: supportsOpacity, onChange: onSelect)
        } label: {
            SwatchDot(
                fill: AnyShapeStyle(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)),
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .help("Custom color")
    }
}

/// Routes the shared NSColorPanel to whichever control opened it last.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()

    private var onChange: ((RGBAColor) -> Void)?

    func open(initial: RGBAColor, showsAlpha: Bool, onChange: @escaping (RGBAColor) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = showsAlpha
        panel.color = NSColor(initial)
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        self.onChange = onChange
        panel.orderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let color = RGBAColor(sender.color) else { return }
        onChange?(color)
    }
}

/// Compact segmented control with SF Symbols.
struct SymbolPicker<Value: Hashable>: View {
    let selection: Value
    let options: [(Value, String, String)]
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = option.0 == selection
                Button {
                    onSelect(option.0)
                } label: {
                    Image(systemName: option.1)
                        .frame(width: 26, height: 24)
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(option.2)
            }
        }
    }
}

/// Menu of preset numeric values.
struct ValueMenu: View {
    let symbol: String
    let value: CGFloat
    let options: [CGFloat]
    let suffix: String
    let help: String
    let onSelect: (CGFloat) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if abs(option - value) < 0.01 {
                        Label(Self.format(option, suffix), systemImage: "checkmark")
                    } else {
                        Text(Self.format(option, suffix))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(Self.format(value, suffix))
                    .monospacedDigit()
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
    }

    static func format(_ value: CGFloat, _ suffix: String) -> String {
        let number = value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
        return suffix.isEmpty ? number : "\(number)\(suffix == "×" ? "" : " ")\(suffix)"
    }
}

struct LabeledSlider: View {
    let symbol: String
    let value: Double
    let range: ClosedRange<Double>
    let help: String
    let onChange: @MainActor (Double) -> Void

    init(symbol: String, value: CGFloat, range: ClosedRange<CGFloat>, help: String, onChange: @escaping @MainActor (CGFloat) -> Void) {
        self.symbol = symbol
        self.value = Double(value)
        self.range = Double(range.lowerBound)...Double(range.upperBound)
        self.help = help
        self.onChange = { onChange(CGFloat($0)) }
    }

    init(symbol: String, value: Double, range: ClosedRange<Double>, help: String, onChange: @escaping @MainActor (Double) -> Void) {
        self.symbol = symbol
        self.value = value
        self.range = range
        self.help = help
        self.onChange = onChange
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range)
                .frame(width: 110)
                .controlSize(.small)
        }
        .help(help)
    }
}

struct CropControls: View {
    let model: EditorModel

    var body: some View {
        Menu {
            ForEach(BackdropAspect.allCases) { aspect in
                Button(aspect == .auto ? "Freeform" : aspect.title) { model.setCropAspect(aspect) }
            }
        } label: {
            Label(model.cropAspect == .auto ? "Freeform" : model.cropAspect.title, systemImage: "aspectratio")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        Button("Auto-Trim") { model.autoTrim() }
            .buttonStyle(.plain)
            .help("Remove uniform borders")
        Button("Reset") { model.resetCrop() }
            .buttonStyle(.plain)
        Divider().frame(height: 18)
        Button("Cancel") { model.cancelCrop() }
            .buttonStyle(.plain)
        Button("Apply") { model.applyCrop() }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
    }
}
