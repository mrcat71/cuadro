import CoreGraphics
import Testing
@testable import CuadroKit

struct RendererTests {
    /// White base image of `width` x `height` pixels.
    static func whiteImage(width: Int, height: Int) -> CGImage {
        PixelBuffer(width: width, height: height, fill: .white).makeImage()!
    }

    /// Checkerboard with 1-pixel cells.
    static func checkerboard(width: Int, height: Int) -> CGImage {
        var buffer = PixelBuffer(width: width, height: height, fill: .white)
        for y in 0..<height {
            for x in 0..<width where (x + y) % 2 == 0 {
                buffer.setColor(.black, x: x, y: y)
            }
        }
        return buffer.makeImage()!
    }

    static func pixels(_ image: CGImage) -> PixelBuffer { PixelBuffer(image: image)! }

    static func isClose(_ a: RGBAColor, _ b: RGBAColor, tolerance: Double = 0.03) -> Bool {
        abs(a.red - b.red) <= tolerance && abs(a.green - b.green) <= tolerance
            && abs(a.blue - b.blue) <= tolerance && abs(a.alpha - b.alpha) <= tolerance
    }

    @Test func rendersRectangleStroke() throws {
        let renderer = DocumentRenderer(baseImage: Self.whiteImage(width: 100, height: 50), scale: 1)
        var style = AnnotationStyle.defaults(for: .rectangle)
        style.shadow = false
        style.color = RGBAColor(red: 1, green: 0, blue: 0)
        let state = DocumentState(annotations: [
            Annotation(kind: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 60, y: 40), style: style),
        ])
        let image = try #require(renderer.render(state))
        #expect(image.width == 100)
        #expect(image.height == 50)
        let pixels = Self.pixels(image)
        #expect(Self.isClose(pixels.color(x: 10, y: 25), RGBAColor(red: 1, green: 0, blue: 0)))
        #expect(Self.isClose(pixels.color(x: 35, y: 25), .white))
        // y-down: the top edge sits at y = 10, not at the bottom of the bitmap.
        #expect(Self.isClose(pixels.color(x: 35, y: 10), RGBAColor(red: 1, green: 0, blue: 0)))
    }

    @Test(arguments: [
        (CGFloat(1), CGFloat(1), 100, 50),
        (CGFloat(2), CGFloat(1), 200, 100),
        (CGFloat(2), CGFloat(0.5), 100, 50),
    ])
    func outputSizeFollowsScale(scale: CGFloat, outputScale: CGFloat, width: Int, height: Int) throws {
        let base = Self.whiteImage(width: Int(100 * scale), height: Int(50 * scale))
        let renderer = DocumentRenderer(baseImage: base, scale: scale)
        let image = try #require(renderer.render(DocumentState(outputScale: outputScale)))
        #expect(image.width == width)
        #expect(image.height == height)
    }

    @Test func cropChangesOutputSize() throws {
        let renderer = DocumentRenderer(baseImage: Self.whiteImage(width: 100, height: 50), scale: 1)
        let image = try #require(renderer.render(DocumentState(crop: CGRect(x: 20, y: 10, width: 40, height: 20))))
        #expect(image.width == 40)
        #expect(image.height == 20)
    }

    @Test func backdropAddsPaddingAndKeepsTransparency() throws {
        let renderer = DocumentRenderer(baseImage: Self.whiteImage(width: 100, height: 50), scale: 1)
        let backdrop = Backdrop(fill: .transparent, padding: 10, cornerRadius: 0, shadow: 0)
        let image = try #require(renderer.render(DocumentState(backdrop: backdrop)))
        #expect(image.width == 120)
        #expect(image.height == 70)
        let pixels = Self.pixels(image)
        #expect(pixels.color(x: 2, y: 2).alpha == 0)
        #expect(Self.isClose(pixels.color(x: 60, y: 35), .white))
    }

    @Test(arguments: [
        (BackdropAspect.auto, CGSize(width: 120, height: 70)),
        (BackdropAspect.square, CGSize(width: 120, height: 120)),
        (BackdropAspect.sixteenNine, CGSize(width: 125, height: 70)),
    ])
    func backdropAspect(aspect: BackdropAspect, expected: CGSize) {
        let backdrop = Backdrop(fill: .transparent, padding: 10, cornerRadius: 0, shadow: 0, aspect: aspect)
        let layout = CanvasLayout.make(imageSize: CGSize(width: 100, height: 50), scale: 1, crop: nil, backdrop: backdrop)
        #expect(layout.canvasSize == expected)
        #expect(layout.imageRect.size == CGSize(width: 100, height: 50))
    }

    @Test func layoutMapsDocumentToCanvas() {
        let layout = CanvasLayout.make(
            imageSize: CGSize(width: 100, height: 50), scale: 2,
            crop: CGRect(x: 20, y: 10, width: 40, height: 20),
            backdrop: Backdrop(fill: .transparent, padding: 8, cornerRadius: 0, shadow: 0)
        )
        #expect(layout.canvasPoint(fromDocument: CGPoint(x: 20, y: 10)) == CGPoint(x: 8, y: 8))
        #expect(layout.documentPoint(fromCanvas: CGPoint(x: 8, y: 8)) == CGPoint(x: 20, y: 10))
    }

    @Test func spotlightDimsOutside() throws {
        let renderer = DocumentRenderer(baseImage: Self.whiteImage(width: 100, height: 50), scale: 1)
        var state = DocumentState(annotations: [
            Annotation(kind: .spotlight, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 30, y: 30)),
        ])
        state.spotlightOpacity = 0.6
        let pixels = Self.pixels(try #require(renderer.render(state)))
        #expect(Self.isClose(pixels.color(x: 20, y: 20), .white))
        #expect(abs(pixels.color(x: 80, y: 40).red - 0.4) < 0.03)
    }

    @Test func pixelateMakesBlocksUniform() throws {
        let renderer = DocumentRenderer(baseImage: Self.checkerboard(width: 64, height: 64), scale: 1)
        var style = AnnotationStyle.defaults(for: .pixelate)
        style.pixelSize = 8
        let state = DocumentState(annotations: [
            Annotation(kind: .pixelate, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 32, y: 32), style: style),
        ])
        let pixels = Self.pixels(try #require(renderer.render(state)))
        #expect(Self.isClose(pixels.color(x: 9, y: 9), pixels.color(x: 10, y: 9)))
        #expect(!Self.isClose(pixels.color(x: 40, y: 40), pixels.color(x: 41, y: 40)))
    }

    @Test func eraseFillsWithSampledColor() throws {
        let renderer = DocumentRenderer(baseImage: Self.whiteImage(width: 40, height: 40), scale: 1)
        var erase = Annotation(kind: .erase, start: CGPoint(x: 5, y: 5), end: CGPoint(x: 20, y: 20))
        erase.fillColor = RGBAColor(red: 0, green: 0, blue: 1)
        let pixels = Self.pixels(try #require(renderer.render(DocumentState(annotations: [erase]))))
        #expect(Self.isClose(pixels.color(x: 10, y: 10), RGBAColor(red: 0, green: 0, blue: 1)))
        #expect(Self.isClose(pixels.color(x: 30, y: 30), .white))
    }

    @Test func textAndCounterDrawInk() throws {
        let renderer = DocumentRenderer(baseImage: Self.whiteImage(width: 200, height: 80), scale: 1)
        var text = Annotation(kind: .text, start: CGPoint(x: 10, y: 10))
        text.text = "Hello"
        text.style.shadow = false
        var counter = Annotation(kind: .counter, start: CGPoint(x: 160, y: 40))
        counter.number = 2
        counter.style.shadow = false
        let pixels = Self.pixels(try #require(renderer.render(DocumentState(annotations: [text, counter]))))
        let textBounds = text.bounds
        #expect(textBounds.width > 30)
        // Pill background uses the annotation color.
        #expect(Self.isClose(pixels.color(x: 12, y: Int(textBounds.midY)), text.style.color, tolerance: 0.05))
        #expect(Self.isClose(pixels.color(x: 160, y: 30), counter.style.color, tolerance: 0.05))
    }

    @Test func outlinedTextDrawsFillAndContrastingStroke() throws {
        let base = PixelBuffer(width: 220, height: 80, fill: .black).makeImage()!
        let renderer = DocumentRenderer(baseImage: base, scale: 1)
        var text = Annotation(kind: .text, start: CGPoint(x: 10, y: 10))
        text.text = "Hello"
        text.style.textStyle = .outline
        text.style.color = RGBAColor(red: 1, green: 0, blue: 0)
        text.style.fontSize = 40
        text.style.shadow = false
        let pixels = Self.pixels(try #require(renderer.render(DocumentState(annotations: [text]))))
        var red = 0
        var white = 0
        let area = PixelRect(covering: text.bounds).clamped(width: pixels.width, height: pixels.height)
        for y in area.y..<area.maxY {
            for x in area.x..<area.maxX {
                let color = pixels.color(x: x, y: y)
                if color.red > 0.9, color.green < 0.2, color.blue < 0.2 { red += 1 }
                if color.red > 0.9, color.green > 0.9, color.blue > 0.9 { white += 1 }
            }
        }
        #expect(red > 50)
        #expect(white > 50)
    }

    @Test func measurementLabelsUseUnitsForScale() {
        let oneX = DocumentRenderer(baseImage: Self.whiteImage(width: 10, height: 10), scale: 1)
        let twoX = DocumentRenderer(baseImage: Self.whiteImage(width: 20, height: 20), scale: 2)
        #expect(oneX.measurementLabel(points: 41.6) == "42 px")
        #expect(twoX.measurementLabel(points: 41.6) == "42 pt")
    }
}
