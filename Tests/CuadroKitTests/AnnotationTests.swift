import CoreGraphics
import Testing
@testable import CuadroKit

struct AnnotationTests {
    static func make(_ kind: AnnotationKind, _ start: CGPoint, _ end: CGPoint, fill: FillMode = .none) -> Annotation {
        var style = AnnotationStyle.defaults(for: kind)
        style.lineWidth = 4
        style.fill = fill
        return Annotation(kind: kind, start: start, end: end, style: style)
    }

    struct HitCase: Sendable, CustomTestStringConvertible {
        let name: String
        let annotation: Annotation
        let point: CGPoint
        let hit: Bool
        var testDescription: String { name }
    }

    @Test(arguments: [
        HitCase(name: "line near", annotation: make(.line, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)), point: CGPoint(x: 50, y: 3), hit: true),
        HitCase(name: "line far", annotation: make(.line, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)), point: CGPoint(x: 50, y: 10), hit: false),
        HitCase(name: "rect border", annotation: make(.rectangle, CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)), point: CGPoint(x: 10, y: 35), hit: true),
        HitCase(name: "hollow rect center", annotation: make(.rectangle, CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)), point: CGPoint(x: 60, y: 35), hit: false),
        HitCase(name: "filled rect center", annotation: make(.rectangle, CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60), fill: .solid), point: CGPoint(x: 60, y: 35), hit: true),
        HitCase(name: "ellipse top", annotation: make(.ellipse, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50)), point: CGPoint(x: 50, y: 1), hit: true),
        HitCase(name: "hollow ellipse center", annotation: make(.ellipse, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50)), point: CGPoint(x: 50, y: 25), hit: false),
        HitCase(name: "blur inside", annotation: make(.blur, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 50)), point: CGPoint(x: 50, y: 25), hit: true),
        HitCase(name: "magnifier corner outside circle", annotation: make(.magnifier, CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)), point: CGPoint(x: 3, y: 3), hit: false),
    ])
    func hitTesting(_ testCase: HitCase) {
        #expect(testCase.annotation.hitTest(testCase.point, tolerance: 2) == testCase.hit)
    }

    @Test func counterHitAndBounds() {
        var counter = Annotation(kind: .counter, start: CGPoint(x: 50, y: 50))
        counter.style.fontSize = 20
        #expect(counter.hitTest(CGPoint(x: 60, y: 50), tolerance: 0))
        #expect(!counter.hitTest(CGPoint(x: 80, y: 50), tolerance: 0))
        #expect(counter.bounds == CGRect(x: 34, y: 34, width: 32, height: 32))
    }

    @Test func handlesPerKind() {
        #expect(Self.make(.arrow, .zero, CGPoint(x: 10, y: 0)).handles.count == 3)
        #expect(Self.make(.line, .zero, CGPoint(x: 10, y: 0)).handles.count == 2)
        #expect(Self.make(.rectangle, .zero, CGPoint(x: 10, y: 10)).handles.count == 8)
        #expect(Annotation(kind: .pen, start: .zero).handles.isEmpty)
        let rect = Self.make(.rectangle, .zero, CGPoint(x: 100, y: 50))
        #expect(rect.handle(at: CGPoint(x: 99, y: 49), radius: 4) == .corner(.bottomRight))
        #expect(rect.handle(at: CGPoint(x: 50, y: 25), radius: 4) == nil)
    }

    @Test func movingHandles() {
        var rect = Self.make(.rectangle, .zero, CGPoint(x: 100, y: 50))
        rect.move(.corner(.bottomRight), to: CGPoint(x: 200, y: 100), constrained: false)
        #expect(rect.rect == CGRect(x: 0, y: 0, width: 200, height: 100))

        var magnifier = Self.make(.magnifier, .zero, CGPoint(x: 100, y: 100))
        magnifier.move(.corner(.bottomRight), to: CGPoint(x: 150, y: 120), constrained: false)
        #expect(magnifier.rect.width == magnifier.rect.height)

        var line = Self.make(.line, .zero, CGPoint(x: 100, y: 0))
        line.move(.end, to: CGPoint(x: 50, y: 52), constrained: true)
        #expect(abs(line.end.x - line.end.y) < 0.001)

        var arrow = Self.make(.arrow, .zero, CGPoint(x: 100, y: 0))
        arrow.move(.bend, to: CGPoint(x: 50, y: 30), constrained: false)
        #expect(arrow.bend == CGPoint(x: 50, y: 30))
        #expect(arrow.curveControl != nil)
    }

    @Test func translateMovesEverything() {
        var arrow = Self.make(.arrow, .zero, CGPoint(x: 100, y: 0))
        arrow.bend = CGPoint(x: 50, y: 20)
        arrow.points = [CGPoint(x: 1, y: 1)]
        arrow.translate(by: CGPoint(x: 10, y: 5))
        #expect(arrow.start == CGPoint(x: 10, y: 5))
        #expect(arrow.end == CGPoint(x: 110, y: 5))
        #expect(arrow.bend == CGPoint(x: 60, y: 25))
        #expect(arrow.points == [CGPoint(x: 11, y: 6)])
    }

    @Test(arguments: [
        (make(.line, .zero, CGPoint(x: 2, y: 0)), true),
        (make(.line, .zero, CGPoint(x: 20, y: 0)), false),
        (make(.rectangle, .zero, CGPoint(x: 2, y: 40)), true),
        (make(.rectangle, .zero, CGPoint(x: 20, y: 40)), false),
        (Annotation(kind: .text, start: .zero), true),
        (Annotation(kind: .counter, start: .zero), false),
    ])
    func degenerateAnnotations(annotation: Annotation, degenerate: Bool) {
        #expect(annotation.isDegenerate == degenerate)
    }

    @Test func nextCounterNumber() {
        var state = DocumentState()
        #expect(state.nextCounterNumber == 1)
        var first = Annotation(kind: .counter, start: .zero)
        first.number = 1
        var third = Annotation(kind: .counter, start: .zero)
        third.number = 3
        state.annotations = [first, third]
        #expect(state.nextCounterNumber == 4)
    }

    @Test func arrowMetricsShrinkOnShortArrows() {
        let long = ArrowGeometry.metrics(lineWidth: 4, length: 200)
        #expect(abs(long.headLength - 14.4) < 0.001)
        #expect(abs(long.headWidth - 12) < 0.001)
        let short = ArrowGeometry.metrics(lineWidth: 4, length: 10)
        #expect(short.headLength <= 4.5 + 0.001)
    }

    @Test func arrowPathsCoverTheirEndpoints() {
        let start = CGPoint(x: 10, y: 10)
        let end = CGPoint(x: 110, y: 60)
        let straight = ArrowGeometry.straightArrowPath(from: start, to: end, lineWidth: 4, doubleHeaded: false)
        #expect(straight.boundingBox.insetBy(dx: -0.5, dy: -0.5).contains(end))
        let double = ArrowGeometry.straightArrowPath(from: start, to: end, lineWidth: 4, doubleHeaded: true)
        #expect(double.boundingBox.insetBy(dx: -0.5, dy: -0.5).contains(start))
        let curved = ArrowGeometry.curvedArrow(from: start, to: end, through: CGPoint(x: 40, y: 70), lineWidth: 4, doubleHeaded: false)
        #expect(curved.heads.boundingBox.insetBy(dx: -0.5, dy: -0.5).contains(end))
        // The shaft bulges through the bend point.
        #expect(curved.shaft.boundingBox.maxY >= 69)
    }
}
