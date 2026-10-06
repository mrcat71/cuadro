import CoreGraphics
import Foundation

/// An sRGB color with components in 0...1.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(red8: UInt8, green8: UInt8, blue8: UInt8, alpha8: UInt8 = 255) {
        self.init(red: Double(red8) / 255, green: Double(green8) / 255, blue: Double(blue8) / 255, alpha: Double(alpha8) / 255)
    }

    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA` (the `#` is optional).
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        if digits.count == 6 {
            self.init(red8: UInt8((value >> 16) & 0xFF), green8: UInt8((value >> 8) & 0xFF), blue8: UInt8(value & 0xFF))
        } else {
            self.init(
                red8: UInt8((value >> 24) & 0xFF), green8: UInt8((value >> 16) & 0xFF),
                blue8: UInt8((value >> 8) & 0xFF), alpha8: UInt8(value & 0xFF)
            )
        }
    }

    /// Converts any CGColor to sRGB.
    public init?(cgColor: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 3
        else { return nil }
        self.init(
            red: Double(components[0]), green: Double(components[1]), blue: Double(components[2]),
            alpha: Double(components.count > 3 ? components[3] : 1)
        )
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)

    /// Annotation swatches (system-like hues).
    public static let palette: [RGBAColor] = [
        RGBAColor(hex: "#FF3B30")!, // red
        RGBAColor(hex: "#FF9500")!, // orange
        RGBAColor(hex: "#FFCC00")!, // yellow
        RGBAColor(hex: "#34C759")!, // green
        RGBAColor(hex: "#007AFF")!, // blue
        RGBAColor(hex: "#AF52DE")!, // purple
        RGBAColor(hex: "#1C1C1E")!, // black
        RGBAColor(hex: "#FFFFFF")!, // white
    ]

    public var red8: UInt8 { Self.byte(red) }
    public var green8: UInt8 { Self.byte(green) }
    public var blue8: UInt8 { Self.byte(blue) }
    public var alpha8: UInt8 { Self.byte(alpha) }

    public func withAlpha(_ alpha: Double) -> RGBAColor {
        RGBAColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    // MARK: Formatting

    /// `#RRGGBB`, or `#RRGGBBAA` when not fully opaque.
    public var hexString: String {
        let rgb = String(format: "#%02X%02X%02X", red8, green8, blue8)
        return alpha8 == 255 ? rgb : rgb + String(format: "%02X", alpha8)
    }

    public var rgbString: String {
        if alpha8 == 255 {
            return "rgb(\(red8), \(green8), \(blue8))"
        }
        return "rgba(\(red8), \(green8), \(blue8), \(Self.trimmed(alpha, digits: 2)))"
    }

    public var hsl: (hue: Double, saturation: Double, lightness: Double) {
        let maxC = max(red, green, blue)
        let minC = min(red, green, blue)
        let lightness = (maxC + minC) / 2
        guard maxC != minC else { return (0, 0, lightness) }
        let delta = maxC - minC
        let saturation = lightness > 0.5 ? delta / (2 - maxC - minC) : delta / (maxC + minC)
        var hue: Double
        if maxC == red {
            hue = (green - blue) / delta + (green < blue ? 6 : 0)
        } else if maxC == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue *= 60
        return (hue, saturation, lightness)
    }

    public var hslString: String {
        let value = hsl
        return "hsl(\(Int(value.hue.rounded()) % 360), \(Int((value.saturation * 100).rounded()))%, \(Int((value.lightness * 100).rounded()))%)"
    }

    /// OKLCH per Björn Ottosson's OKLab: lightness 0...1, chroma, hue in degrees.
    public var oklch: (lightness: Double, chroma: Double, hue: Double) {
        let r = Self.linearize(red), g = Self.linearize(green), b = Self.linearize(blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        let chroma = (a * a + bb * bb).squareRoot()
        var hue = atan2(bb, a) * 180 / .pi
        if hue < 0 { hue += 360 }
        if chroma < 0.0002 { hue = 0 }
        return (lightness, chroma, hue)
    }

    public var oklchString: String {
        let value = oklch
        return String(format: "oklch(%.1f%% %.3f %.1f)", value.lightness * 100, value.chroma, value.hue)
    }

    public func string(in format: ColorFormat) -> String {
        switch format {
        case .hex: hexString
        case .rgb: rgbString
        case .hsl: hslString
        case .oklch: oklchString
        }
    }

    // MARK: Contrast

    /// WCAG 2 relative luminance.
    public var relativeLuminance: Double {
        0.2126 * Self.linearize(red) + 0.7152 * Self.linearize(green) + 0.0722 * Self.linearize(blue)
    }

    /// WCAG 2 contrast ratio, 1...21.
    public static func contrastRatio(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let la = a.relativeLuminance
        let lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Black text on light colors (yellow, white), white text on everything else, matching the
    /// look of system labels on saturated fills.
    public var contrastingTextColor: RGBAColor {
        relativeLuminance > 0.5 ? .black : .white
    }

    // MARK: Helpers

    static func linearize(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }

    static func byte(_ component: Double) -> UInt8 {
        UInt8(max(0, min(255, (component * 255).rounded())))
    }

    static func trimmed(_ value: Double, digits: Int) -> String {
        var text = String(format: "%.\(digits)f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

public enum ColorFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case hex, rgb, hsl, oklch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .oklch: "OKLCH"
        }
    }
}
