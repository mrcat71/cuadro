import AppKit
import CuadroKit

/// A made-up infrastructure dashboard for the UI self-check and the README: stat tiles, a
/// requests chart with a deploy spike, a CI pipeline, a node table with a failing node and a
/// config block with a fake token. Drawn in an 800 × 500 pt layout (y down), scaled to fit.
enum SampleBoard {
    static func image(width: Int, height: Int) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(RGBAColor(hex: "#EEF1F7")!.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(CGFloat(width) / 800, CGFloat(height) / 500)
        ctx.translateBy(x: (CGFloat(width) - 800 * scale) / 2, y: CGFloat(height) - (CGFloat(height) - 500 * scale) / 2)
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let board = Board(ctx: ctx, space: space)
        board.topBar()
        board.tiles()
        board.requestsChart(CGRect(x: 20, y: 140, width: 500, height: 200))
        board.pipeline(CGRect(x: 536, y: 140, width: 244, height: 200))
        board.nodes(CGRect(x: 20, y: 356, width: 380, height: 128))
        board.config(CGRect(x: 416, y: 356, width: 364, height: 128))
        return ctx.makeImage()!
    }
}

private struct Board {
    let ctx: CGContext
    let space: CGColorSpace

    static let ink = "#111827"
    static let muted = "#6B7280"
    static let line = "#E5E7EB"
    static let accent = "#4F46E5"
    static let green = "#16A34A"
    static let amber = "#D97706"
    static let red = "#DC2626"

    func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
        RGBAColor(hex: hex)!.withAlpha(alpha).cgColor
    }

    func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, hex: String = Board.ink, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: NSColor(RGBAColor(hex: hex)!),
        ]).draw(at: point)
    }

    func textWidth(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).size().width
    }

    func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    func fill(_ path: CGPath, _ hex: String, _ alpha: CGFloat = 1) {
        ctx.addPath(path)
        ctx.setFillColor(color(hex, alpha))
        ctx.fillPath()
    }

    func card(_ rect: CGRect, title: String) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: color("#1F2937", 0.08))
        fill(rounded(rect, 12), "#FFFFFF")
        ctx.restoreGState()
        ctx.addPath(rounded(rect, 12))
        ctx.setStrokeColor(color(Board.line))
        ctx.setLineWidth(1)
        ctx.strokePath()
        text(title, at: CGPoint(x: rect.minX + 16, y: rect.minY + 12), size: 11.5, weight: .semibold, hex: Board.ink)
    }

    func pill(_ string: String, at point: CGPoint, hex: String, filled: Bool = false) -> CGRect {
        let width = textWidth(string, size: 10, weight: .semibold) + 16
        let rect = CGRect(x: point.x, y: point.y, width: width, height: 20)
        fill(rounded(rect, 10), hex, filled ? 1 : 0.12)
        text(string, at: CGPoint(x: rect.minX + 8, y: rect.minY + 3.5), size: 10, weight: .semibold, hex: filled ? "#FFFFFF" : hex)
        return rect
    }

    // MARK: Header and tiles

    func topBar() {
        fill(CGPath(rect: CGRect(x: 0, y: 0, width: 800, height: 46), transform: nil), "#FFFFFF")
        ctx.setFillColor(color(Board.line))
        ctx.fill(CGRect(x: 0, y: 46, width: 800, height: 1))
        let logo = CGRect(x: 20, y: 13, width: 20, height: 20)
        let gradient = CGGradient(colorsSpace: space, colors: [color("#6366F1"), color("#06B6D4")] as CFArray, locations: nil)!
        ctx.saveGState()
        ctx.addPath(rounded(logo, 6))
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: logo.minX, y: logo.minY), end: CGPoint(x: logo.maxX, y: logo.maxY), options: [])
        ctx.restoreGState()
        text("Platform", at: CGPoint(x: 48, y: 13), size: 14, weight: .bold)
        _ = pill("prod · eu-west-1", at: CGPoint(x: 120, y: 13), hex: Board.green)
        var x: CGFloat = 270
        for (index, tab) in ["Overview", "Deploys", "Clusters", "Alerts"].enumerated() {
            text(tab, at: CGPoint(x: x, y: 15), size: 12, weight: index == 0 ? .semibold : .regular, hex: index == 0 ? Board.ink : Board.muted)
            let width = textWidth(tab, size: 12, weight: index == 0 ? .semibold : .regular)
            if index == 0 {
                fill(rounded(CGRect(x: x, y: 40, width: width, height: 3), 1.5), Board.accent)
            }
            x += width + 22
        }
        _ = pill("Alerts 3", at: CGPoint(x: 600, y: 13), hex: Board.red)
        _ = pill("Last 6 h", at: CGPoint(x: 668, y: 13), hex: Board.muted)
        fill(CGPath(ellipseIn: CGRect(x: 752, y: 12, width: 24, height: 24), transform: nil), "#C7D2FE")
        text("AS", at: CGPoint(x: 757, y: 17), size: 10, weight: .bold, hex: Board.accent)
    }

    func tiles() {
        let tiles: [(String, String, String, String)] = [
            ("Availability", "99.98%", "30 d SLO 99.95%", Board.green),
            ("p95 latency", "182 ms", "▲ 2.1× since 14:20", Board.red),
            ("Error rate", "0.21%", "budget 64% left", Board.amber),
            ("Deploys today", "14", "2 rolled back", Board.accent),
        ]
        for (index, tile) in tiles.enumerated() {
            let rect = CGRect(x: 20 + CGFloat(index) * 192, y: 60, width: 180, height: 66)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 8, color: color("#1F2937", 0.08))
            fill(rounded(rect, 12), "#FFFFFF")
            ctx.restoreGState()
            fill(rounded(CGRect(x: rect.minX, y: rect.minY + 14, width: 3, height: 38), 1.5), tile.3)
            text(tile.0, at: CGPoint(x: rect.minX + 14, y: rect.minY + 9), size: 10.5, hex: Board.muted)
            text(tile.1, at: CGPoint(x: rect.minX + 14, y: rect.minY + 23), size: 21, weight: .bold)
            text(tile.2, at: CGPoint(x: rect.minX + 14, y: rect.minY + 49), size: 9.5, weight: .medium, hex: tile.3)
        }
    }

    // MARK: Requests chart

    func requestsChart(_ rect: CGRect) {
        card(rect, title: "Requests per second · api-gateway")
        _ = pill("p95", at: CGPoint(x: rect.maxX - 92, y: rect.minY + 10), hex: Board.accent, filled: true)
        _ = pill("rps", at: CGPoint(x: rect.maxX - 52, y: rect.minY + 10), hex: Board.muted)
        let plot = CGRect(x: rect.minX + 40, y: rect.minY + 44, width: rect.width - 60, height: rect.height - 74)
        for row in 0...3 {
            let y = plot.minY + plot.height * CGFloat(row) / 3
            ctx.setFillColor(color(Board.line))
            ctx.fill(CGRect(x: plot.minX, y: y, width: plot.width, height: 1))
            text(["3k", "2k", "1k", "0"][row], at: CGPoint(x: rect.minX + 16, y: y - 7), size: 9, hex: Board.muted)
        }
        for (index, label) in ["12:00", "13:00", "14:00", "15:00", "16:00", "17:00", "18:00"].enumerated() {
            let x = plot.minX + plot.width * CGFloat(index) / 6
            text(label, at: CGPoint(x: x - 13, y: plot.maxY + 7), size: 9, hex: Board.muted)
        }
        let values: [CGFloat] = [0.42, 0.46, 0.44, 0.5, 0.48, 0.55, 0.52, 0.58, 0.95, 0.88, 0.63, 0.6, 0.57, 0.6, 0.62, 0.59, 0.64, 0.61, 0.66]
        let points = values.enumerated().map { index, value in
            CGPoint(x: plot.minX + plot.width * CGFloat(index) / CGFloat(values.count - 1), y: plot.maxY - plot.height * value)
        }
        let curve = Self.smoothPath(points)
        let area = CGMutablePath()
        area.addPath(curve)
        area.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        area.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        area.closeSubpath()
        ctx.saveGState()
        ctx.addPath(area)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: space, colors: [color(Board.accent, 0.28), color(Board.accent, 0.02)] as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plot.minY), end: CGPoint(x: 0, y: plot.maxY), options: [])
        ctx.restoreGState()
        ctx.addPath(curve)
        ctx.setStrokeColor(color(Board.accent))
        ctx.setLineWidth(2.2)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        // The deploy marker at the spike.
        let spike = points[8]
        ctx.setStrokeColor(color(Board.red, 0.6))
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.move(to: CGPoint(x: spike.x, y: plot.minY))
        ctx.addLine(to: CGPoint(x: spike.x, y: plot.maxY))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        fill(CGPath(ellipseIn: CGRect(x: spike.x - 4.5, y: spike.y - 4.5, width: 9, height: 9), transform: nil), Board.red)
        text("deploy 4f2a1c", at: CGPoint(x: spike.x + 6, y: plot.maxY - 16), size: 9, weight: .medium, hex: Board.red)
    }

    /// Catmull-Rom through `points`, as cubic Béziers.
    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 0..<(points.count - 1) {
            let p0 = points[max(index - 1, 0)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(index + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    // MARK: Pipeline, nodes, config

    func pipeline(_ rect: CGRect) {
        card(rect, title: "Pipeline · checkout-service")
        let stages: [(String, String, String)] = [
            ("Build", "1m 12s", Board.green),
            ("Unit tests", "3m 40s", Board.green),
            ("Security scan", "48s", Board.green),
            ("Canary 25%", "running", Board.amber),
            ("Promote to 100%", "waiting", "#9CA3AF"),
        ]
        for (index, stage) in stages.enumerated() {
            let y = rect.minY + 44 + CGFloat(index) * 30
            let dot = CGRect(x: rect.minX + 18, y: y + 2, width: 14, height: 14)
            if index < stages.count - 1 {
                ctx.setFillColor(color(Board.line))
                ctx.fill(CGRect(x: dot.midX - 1, y: dot.maxY + 2, width: 2, height: 14))
            }
            fill(CGPath(ellipseIn: dot, transform: nil), stage.2, index < 3 ? 1 : 0.2)
            if index < 3 {
                text("✓", at: CGPoint(x: dot.minX + 3, y: dot.minY - 0.5), size: 10, weight: .bold, hex: "#FFFFFF")
            } else {
                fill(CGPath(ellipseIn: dot.insetBy(dx: 4, dy: 4), transform: nil), stage.2)
            }
            text(stage.0, at: CGPoint(x: rect.minX + 42, y: y), size: 12, weight: index == 3 ? .semibold : .regular)
            let width = textWidth(stage.1, size: 10.5)
            text(stage.1, at: CGPoint(x: rect.maxX - 16 - width, y: y + 1.5), size: 10.5, hex: stage.2 == Board.green ? Board.muted : stage.2)
        }
    }

    func nodes(_ rect: CGRect) {
        card(rect, title: "Nodes · eks-prod")
        let rows: [(String, String, CGFloat)] = [
            ("ip-10-0-1-12", "Ready", 0.48),
            ("ip-10-0-2-31", "Ready", 0.63),
            ("ip-10-0-3-17", "NotReady", 0.97),
            ("ip-10-0-4-08", "Ready", 0.35),
        ]
        for (index, row) in rows.enumerated() {
            let y = rect.minY + 38 + CGFloat(index) * 21
            let failing = row.1 == "NotReady"
            text(row.0, at: CGPoint(x: rect.minX + 16, y: y), size: 11, mono: true)
            let status = failing ? Board.red : Board.green
            fill(CGPath(ellipseIn: CGRect(x: rect.minX + 132, y: y + 4.5, width: 7, height: 7), transform: nil), status)
            text(row.1, at: CGPoint(x: rect.minX + 144, y: y), size: 11, weight: failing ? .semibold : .regular, hex: failing ? Board.red : Board.ink)
            let bar = CGRect(x: rect.minX + 222, y: y + 4, width: 110, height: 7)
            fill(rounded(bar, 3.5), "#E5E7EB")
            fill(rounded(CGRect(x: bar.minX, y: bar.minY, width: bar.width * row.2, height: bar.height), 3.5), failing ? Board.red : Board.accent)
            text("\(Int(row.2 * 100))%", at: CGPoint(x: bar.maxX + 8, y: y), size: 10.5, hex: Board.muted)
        }
    }

    func config(_ rect: CGRect) {
        card(rect, title: "values.yaml · checkout-service")
        let lines: [(String, String)] = [
            ("replicas:", "6"),
            ("image:", "registry.internal/checkout:4f2a1c"),
            ("vaultToken:", "s.k3Z9-not-a-real-token-q7Rf2"),
            ("region:", "eu-west-1"),
        ]
        for (index, line) in lines.enumerated() {
            let y = rect.minY + 38 + CGFloat(index) * 21
            text("\(index + 1)", at: CGPoint(x: rect.minX + 16, y: y), size: 10.5, hex: "#9CA3AF", mono: true)
            text(line.0, at: CGPoint(x: rect.minX + 34, y: y), size: 11, hex: "#7C3AED", mono: true)
            let keyWidth = NSAttributedString(string: line.0 + " ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)]).size().width
            text(line.1, at: CGPoint(x: rect.minX + 34 + keyWidth, y: y), size: 11, hex: "#0F766E", mono: true)
        }
    }
}
