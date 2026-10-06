import CoreGraphics
import CoreText
import Foundation

/// Text measurement and drawing shared by the canvas, export and the inline editor.
public enum TextLayout {
    /// Semibold system font.
    public static func font(size: CGFloat, weight: CGFloat = 0.3) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let traits = [kCTFontWeightTrait: weight] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base),
            [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    public static func lineHeight(of font: CTFont) -> CGFloat {
        CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
    }

    /// Inner padding between the text and its bounds.
    public static func padding(for style: AnnotationStyle) -> CGSize {
        switch style.textStyle {
        case .pill: CGSize(width: (style.fontSize * 0.45).rounded(), height: (style.fontSize * 0.22).rounded())
        case .outline: CGSize(width: (style.fontSize * 0.12).rounded(.up), height: (style.fontSize * 0.08).rounded(.up))
        case .plain: CGSize(width: 2, height: 1)
        }
    }

    /// Lines of the text; an empty string still has one (empty) line for the caret.
    public static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    static func makeLine(_ string: String, font: CTFont) -> CTLine {
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, string as CFString, attributes)!
        return CTLineCreateWithAttributedString(attributed)
    }

    /// Size of a text annotation including padding.
    public static func size(of text: String, style: AnnotationStyle) -> CGSize {
        let font = font(size: style.fontSize)
        let lineHeight = lineHeight(of: font)
        let rows = lines(of: text)
        var width: CGFloat = 0
        for row in rows {
            let line = makeLine(row.isEmpty ? " " : row, font: font)
            width = max(width, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        let pad = padding(for: style)
        return CGSize(
            width: (width + pad.width * 2).rounded(.up),
            height: (lineHeight * CGFloat(rows.count) + pad.height * 2).rounded(.up)
        )
    }

    /// Draws a text annotation with its top-left corner at `origin` in a y-down context.
    public static func draw(_ text: String, style: AnnotationStyle, at origin: CGPoint, in ctx: CGContext) {
        let font = font(size: style.fontSize)
        let lineHeight = lineHeight(of: font)
        let ascent = CTFontGetAscent(font)
        let size = size(of: text, style: style)
        let pad = padding(for: style)
        let box = CGRect(origin: origin, size: size)

        var textColor = style.color
        ctx.saveGState()
        if style.textStyle == .pill {
            let radius = min(size.height / 2, style.fontSize * 0.5)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(style.color.cgColor)
            ctx.fillPath()
            textColor = style.color.contrastingTextColor
            // The pill already casts the shadow; keep the glyphs crisp.
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }

        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let rows = lines(of: text)
        func drawRows() {
            for (index, row) in rows.enumerated() where !row.isEmpty {
                let line = makeLine(row, font: font)
                ctx.textPosition = CGPoint(
                    x: origin.x + pad.width,
                    y: origin.y + pad.height + CGFloat(index) * lineHeight + ascent
                )
                CTLineDraw(line, ctx)
            }
        }

        if style.textStyle == .outline {
            ctx.saveGState()
            ctx.setTextDrawingMode(.stroke)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(max(2, style.fontSize * 0.18))
            ctx.setStrokeColor(style.color.contrastingTextColor.cgColor)
            drawRows()
            ctx.restoreGState()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        }

        ctx.setTextDrawingMode(.fill)
        ctx.setFillColor(textColor.cgColor)
        drawRows()
        ctx.restoreGState()
    }

    /// Draws a single centered line (counter numbers, ruler labels) at `center`.
    public static func drawCentered(_ string: String, font: CTFont, color: RGBAColor, center: CGPoint, in ctx: CGContext) {
        let line = makeLine(string, font: font)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setTextDrawingMode(.fill)
        ctx.setFillColor(color.cgColor)
        ctx.textPosition = CGPoint(x: center.x - width / 2, y: center.y + (ascent - descent) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Width and height of a single line.
    public static func lineSize(_ string: String, font: CTFont) -> CGSize {
        let line = makeLine(string, font: font)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        return CGSize(width: width, height: ascent + descent)
    }
}
