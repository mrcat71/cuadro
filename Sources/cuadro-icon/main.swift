// Renders the Cuadro app icon as an .iconset directory for `iconutil`.
// Usage: cuadro-icon <output.iconset>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas: CGFloat = 1024

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Superellipse ("squircle") close to the macOS icon shape.
func squirclePath(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let steps = 720
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t)
        let s = sin(t)
        let x = a * copysign(pow(abs(c), 2 / exponent), c)
        let y = b * copysign(pow(abs(s), 2 / exponent), s)
        let point = CGPoint(x: rect.midX + x, y: rect.midY + y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squirclePath(in: tile)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: color(0x000000, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x4F46E5))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: indigo to violet to pink.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let background = CGGradient(
        colorsSpace: space,
        colors: [color(0x4F7CFF), color(0x7C4DFF), color(0xE85DBA)] as CFArray,
        locations: [0, 0.55, 1]
    )!
    ctx.drawLinearGradient(
        background,
        start: CGPoint(x: tile.minX, y: tile.maxY),
        end: CGPoint(x: tile.maxX, y: tile.minY),
        options: []
    )
    // Glassy highlight on the upper half.
    let highlight = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF, alpha: 0.28), color(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        highlight,
        startCenter: CGPoint(x: tile.midX - 120, y: tile.maxY - 60),
        startRadius: 0,
        endCenter: CGPoint(x: tile.midX - 120, y: tile.maxY - 60),
        endRadius: 620,
        options: []
    )
    ctx.restoreGState()

    // Picture inside the frame: sun and two mountains.
    let frame = tile.insetBy(dx: 190, dy: 190)
    ctx.saveGState()
    let inner = CGPath(roundedRect: frame.insetBy(dx: 34, dy: 34), cornerWidth: 40, cornerHeight: 40, transform: nil)
    ctx.addPath(inner)
    ctx.clip()
    ctx.setFillColor(color(0xFFFFFF, alpha: 0.16))
    ctx.fill(frame)
    ctx.setFillColor(color(0xFFD84D))
    ctx.fillEllipse(in: CGRect(x: frame.maxX - 190, y: frame.maxY - 190, width: 110, height: 110))
    let back = CGMutablePath()
    back.move(to: CGPoint(x: frame.minX + 20, y: frame.minY + 20))
    back.addLine(to: CGPoint(x: frame.minX + 200, y: frame.minY + 250))
    back.addLine(to: CGPoint(x: frame.minX + 330, y: frame.minY + 120))
    back.addLine(to: CGPoint(x: frame.minX + 330, y: frame.minY + 20))
    back.closeSubpath()
    ctx.addPath(back)
    ctx.setFillColor(color(0xFFFFFF, alpha: 0.55))
    ctx.fillPath()
    let front = CGMutablePath()
    front.move(to: CGPoint(x: frame.minX + 120, y: frame.minY + 20))
    front.addLine(to: CGPoint(x: frame.minX + 330, y: frame.minY + 300))
    front.addLine(to: CGPoint(x: frame.maxX - 20, y: frame.minY + 20))
    front.closeSubpath()
    ctx.addPath(front)
    ctx.setFillColor(color(0xFFFFFF, alpha: 0.92))
    ctx.fillPath()
    ctx.restoreGState()

    // Viewfinder corner brackets.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x1E1B4B, alpha: 0.35))
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(52)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let arm: CGFloat = 130
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: frame.minX, y: frame.maxY), 1, -1),
        (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
        (CGPoint(x: frame.minX, y: frame.minY), 1, 1),
        (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
    ]
    for (corner, dx, dy) in corners {
        let bracket = CGMutablePath()
        bracket.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        bracket.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * 30))
        bracket.addQuadCurve(to: CGPoint(x: corner.x + dx * 30, y: corner.y), control: corner)
        bracket.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        ctx.addPath(bracket)
    }
    ctx.strokePath()
    ctx.restoreGState()
}

func renderMaster() -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    drawIcon(in: ctx)
    return ctx.makeImage()!
}

func resized(_ image: CGImage, to size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: cuadro-icon <output.iconset>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let master = renderMaster()
    let variants: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for variant in variants {
        let image = variant.pixels == Int(canvas) ? master : resized(master, to: variant.pixels)
        try writePNG(image, to: output.appendingPathComponent("\(variant.name).png"))
    }
} catch {
    FileHandle.standardError.write(Data("cuadro-icon: \(error)\n".utf8))
    exit(1)
}
