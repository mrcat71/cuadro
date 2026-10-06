import Testing
@testable import CuadroKit

struct ColorTests {
    @Test(arguments: [
        ("#FF0000", RGBAColor(red: 1, green: 0, blue: 0)),
        ("0f0", RGBAColor(red: 0, green: 1, blue: 0)),
        ("  #0000FF  ", RGBAColor(red: 0, green: 0, blue: 1)),
        ("#FFFFFF00", RGBAColor(red: 1, green: 1, blue: 1, alpha: 0)),
    ])
    func parsesHex(input: String, expected: RGBAColor) {
        #expect(RGBAColor(hex: input) == expected)
    }

    @Test(arguments: ["#GG0000", "#12345", "", "#1234567"])
    func rejectsInvalidHex(input: String) {
        #expect(RGBAColor(hex: input) == nil)
    }

    @Test func formatsColors() {
        let orange = RGBAColor(red8: 255, green8: 128, blue8: 0)
        #expect(orange.hexString == "#FF8000")
        #expect(orange.rgbString == "rgb(255, 128, 0)")
        #expect(orange.withAlpha(0.5).hexString == "#FF800080")
        #expect(orange.withAlpha(0.5).rgbString == "rgba(255, 128, 0, 0.5)")
        #expect(orange.string(in: .hex) == "#FF8000")
    }

    @Test(arguments: [
        (RGBAColor(red: 1, green: 0, blue: 0), "hsl(0, 100%, 50%)"),
        (RGBAColor(red: 1, green: 1, blue: 1), "hsl(0, 0%, 100%)"),
        (RGBAColor(red: 0, green: 0, blue: 1), "hsl(240, 100%, 50%)"),
        (RGBAColor(hex: "#336699")!, "hsl(210, 50%, 40%)"),
    ])
    func formatsHSL(color: RGBAColor, expected: String) {
        #expect(color.hslString == expected)
    }

    @Test func convertsToOKLCH() {
        let white = RGBAColor.white.oklch
        #expect(abs(white.lightness - 1) < 0.001)
        #expect(white.chroma < 0.001)

        let red = RGBAColor(red: 1, green: 0, blue: 0).oklch
        #expect(abs(red.lightness - 0.628) < 0.002)
        #expect(abs(red.chroma - 0.2577) < 0.002)
        #expect(abs(red.hue - 29.23) < 0.1)
        #expect(RGBAColor(red: 1, green: 0, blue: 0).oklchString == "oklch(62.8% 0.258 29.2)")
    }

    @Test(arguments: [
        (RGBAColor.black, RGBAColor.white, 21.0),
        (RGBAColor.white, RGBAColor.white, 1.0),
        (RGBAColor(hex: "#777777")!, RGBAColor.white, 4.48),
    ])
    func contrastRatio(a: RGBAColor, b: RGBAColor, expected: Double) {
        #expect(abs(RGBAColor.contrastRatio(a, b) - expected) < 0.01)
    }

    @Test func picksReadableTextColor() {
        #expect(RGBAColor(hex: "#FFCC00")!.contrastingTextColor == .black)
        #expect(RGBAColor(hex: "#1E3A8A")!.contrastingTextColor == .white)
    }
}
