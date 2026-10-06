import AppKit
import CuadroKit
import SwiftUI

/// Backdrop settings popover.
struct BackdropPanel: View {
    let model: EditorModel

    private var backdrop: Backdrop { model.document.backdrop ?? AppSettings.shared.backdrop }
    private var isOn: Bool { model.document.backdrop != nil }

    private var solidColor: RGBAColor? {
        if case .solid(let color) = backdrop.fill { return color }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { isOn }, set: { model.setBackdrop($0 ? backdrop : nil) })) {
                Text("Backdrop").font(.headline)
            }
            .toggleStyle(.switch)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(32), spacing: 10), count: 6), spacing: 10) {
                ForEach(Backdrop.presets) { preset in
                    swatch(selected: isOn && backdrop.fill == .gradient(preset)) {
                        LinearGradient(colors: preset.colors.map(Color.init), startPoint: .topLeading, endPoint: .bottomTrailing)
                    } action: {
                        model.updateBackdrop { $0.fill = .gradient(preset) }
                    }
                    .help(preset.name)
                }
                swatch(selected: isOn && backdrop.fill == .transparent) {
                    Checkerboard()
                } action: {
                    model.updateBackdrop { $0.fill = .transparent }
                }
                .help("Transparent")
                CustomColorButton(color: solidColor ?? .white, isSelected: isOn && solidColor != nil, supportsOpacity: false) { color in
                    model.updateBackdrop { $0.fill = .solid(color) }
                }
                .scaleEffect(1.5)
                .frame(width: 32, height: 32)
                .help("Solid color")
            }

            VStack(spacing: 10) {
                slider("Padding", value: Double(backdrop.padding), range: 0...240) { value in model.updateBackdrop { $0.padding = CGFloat(value) } }
                slider("Corners", value: Double(backdrop.cornerRadius), range: 0...48) { value in model.updateBackdrop { $0.cornerRadius = CGFloat(value) } }
                slider("Shadow", value: backdrop.shadow, range: 0...1) { value in model.updateBackdrop { $0.shadow = value } }
            }
            .disabled(!isOn)

            Picker("Aspect", selection: Binding(get: { backdrop.aspect }, set: { value in model.updateBackdrop { $0.aspect = value } })) {
                ForEach(BackdropAspect.allCases) { aspect in
                    Text(aspect.title).tag(aspect)
                }
            }
            .disabled(!isOn)
        }
        .padding(18)
        .frame(width: 300)
    }

    private func swatch<Fill: View>(selected: Bool, @ViewBuilder fill: () -> Fill, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            fill()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, onChange: @escaping @MainActor (Double) -> Void) -> some View {
        HStack {
            Text(title)
                .frame(width: 64, alignment: .leading)
                .foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: range)
        }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 7
            for row in 0..<Int(size.height / cell + 1) {
                for column in 0..<Int(size.width / cell + 1) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(.gray.opacity(0.35)))
                }
            }
        }
        .background(.white)
    }
}

/// Recognized text sheet.
struct OCRResultView: View {
    let result: OCRResult
    let dismiss: () -> Void
    @State private var text: String

    init(result: OCRResult, dismiss: @escaping () -> Void) {
        self.result = result
        self.dismiss = dismiss
        _text = State(initialValue: result.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Recognized Text", systemImage: "text.viewfinder")
                .font(.headline)
            if !result.barcodes.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(result.barcodes, id: \.self) { code in
                        HStack {
                            Image(systemName: "qrcode")
                            Text(code)
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer()
                            if let url = URL(string: code), url.scheme?.hasPrefix("http") == true {
                                Button("Open") { NSWorkspace.shared.open(url) }
                            }
                            Button("Copy") { Pasteboard.copy(text: code) }
                        }
                    }
                }
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
            if !result.text.isEmpty {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 220)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("The text was copied to the clipboard.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Copy") { Pasteboard.copy(text: text) }
                    .buttonStyle(.glass)
                    .disabled(text.isEmpty)
                Button("Done", action: dismiss)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

/// Export size sheet.
struct ResizeSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var percent: Double = 100

    var body: some View {
        let base = model.renderer.layout(for: model.document).canvasSize
        let pixelsPerPoint = AppSettings.shared.downscaleRetina ? 1 : model.scale
        VStack(alignment: .leading, spacing: 16) {
            Text("Resize Image").font(.headline)
            HStack(spacing: 6) {
                ForEach([25.0, 50, 75, 100, 150, 200], id: \.self) { value in
                    Button("\(Int(value))%") { percent = value }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
            HStack {
                Slider(value: $percent, in: 10...400, step: 5)
                Text(verbatim: "\(Int(percent))%")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            Text(verbatim: "Result: \(Int((base.width * pixelsPerPoint * percent / 100).rounded())) × \(Int((base.height * pixelsPerPoint * percent / 100).rounded())) px")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.setOutputScale(percent / 100)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { percent = Double(model.document.outputScale * 100) }
    }
}
