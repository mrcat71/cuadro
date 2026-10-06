import CuadroKit

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, line, rectangle, ellipse, pen, highlighter, text, counter
    case obscure, erase, spotlight, magnifier, ruler, picker, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .counter: "Step Counter"
        case .obscure: "Pixelate / Blur"
        case .erase: "Smart Erase"
        case .spotlight: "Spotlight"
        case .magnifier: "Magnifier"
        case .ruler: "Ruler"
        case .picker: "Color Picker"
        case .crop: "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .obscure: "checkerboard.rectangle"
        case .erase: "eraser"
        case .spotlight: "flashlight.on.fill"
        case .magnifier: "plus.magnifyingglass"
        case .ruler: "ruler"
        case .picker: "eyedropper"
        case .crop: "crop"
        }
    }

    /// Single-key shortcut in the editor.
    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rectangle: "r"
        case .ellipse: "o"
        case .pen: "p"
        case .highlighter: "h"
        case .text: "t"
        case .counter: "n"
        case .obscure: "b"
        case .erase: "e"
        case .spotlight: "s"
        case .magnifier: "m"
        case .ruler: "u"
        case .picker: "i"
        case .crop: "c"
        }
    }

    static func forKey(_ character: Character) -> EditorTool? {
        allCases.first { $0.key == character }
    }

    /// Annotation kind created by the tool (pixelate/blur is decided by the model).
    var kind: AnnotationKind? {
        switch self {
        case .arrow: .arrow
        case .line: .line
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .pen: .pen
        case .highlighter: .highlighter
        case .text: .text
        case .counter: .counter
        case .obscure: .pixelate
        case .erase: .erase
        case .spotlight: .spotlight
        case .magnifier: .magnifier
        case .ruler: .measure
        case .select, .picker, .crop: nil
        }
    }

    /// Tool that edits a given annotation kind.
    static func tool(for kind: AnnotationKind) -> EditorTool? {
        switch kind {
        case .pixelate, .blur: .obscure
        case .image: nil
        default: allCases.first { $0.kind == kind }
        }
    }

    static let paletteGroups: [[EditorTool]] = [
        [.select],
        [.arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .text, .counter],
        [.obscure, .erase, .spotlight, .magnifier],
        [.ruler, .picker, .crop],
    ]
}

extension AnnotationKind {
    var usesColor: Bool {
        switch self {
        case .pixelate, .blur, .erase, .spotlight, .image: false
        default: true
        }
    }

    var usesLineWidth: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse, .pen, .measure, .magnifier: true
        default: false
        }
    }

    var usesShadow: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse, .pen, .text, .counter, .measure, .magnifier, .image: true
        default: false
        }
    }

    var displayName: String {
        switch self {
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .pen: "Drawing"
        case .highlighter: "Highlight"
        case .text: "Text"
        case .counter: "Step"
        case .pixelate: "Pixelate"
        case .blur: "Blur"
        case .erase: "Erase"
        case .spotlight: "Spotlight"
        case .magnifier: "Magnifier"
        case .measure: "Measurement"
        case .image: "Image"
        }
    }
}
