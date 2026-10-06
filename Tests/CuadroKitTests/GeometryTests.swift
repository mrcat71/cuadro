import CoreGraphics
import Testing
@testable import CuadroKit

struct GeometryTests {
    struct DragCase: Sendable, CustomTestStringConvertible {
        let name: String
        let start: CGPoint
        let current: CGPoint
        let square: Bool
        let fromCenter: Bool
        let expected: CGRect
        var testDescription: String { name }
    }

    @Test(arguments: [
        DragCase(name: "down-right", start: CGPoint(x: 10, y: 10), current: CGPoint(x: 30, y: 50), square: false, fromCenter: false, expected: CGRect(x: 10, y: 10, width: 20, height: 40)),
        DragCase(name: "up-left", start: CGPoint(x: 30, y: 50), current: CGPoint(x: 10, y: 10), square: false, fromCenter: false, expected: CGRect(x: 10, y: 10, width: 20, height: 40)),
        DragCase(name: "square", start: CGPoint(x: 0, y: 0), current: CGPoint(x: 10, y: 30), square: true, fromCenter: false, expected: CGRect(x: 0, y: 0, width: 30, height: 30)),
        DragCase(name: "square towards negative x", start: CGPoint(x: 0, y: 0), current: CGPoint(x: -10, y: 5), square: true, fromCenter: false, expected: CGRect(x: -10, y: 0, width: 10, height: 10)),
        DragCase(name: "from center", start: CGPoint(x: 50, y: 50), current: CGPoint(x: 60, y: 70), square: false, fromCenter: true, expected: CGRect(x: 40, y: 30, width: 20, height: 40)),
    ])
    func dragRect(_ testCase: DragCase) {
        let rect = Geometry.dragRect(from: testCase.start, to: testCase.current, square: testCase.square, fromCenter: testCase.fromCenter)
        #expect(rect == testCase.expected)
    }

    @Test func snapAngleKeepsDistanceAndSnapsToAxis() {
        let snapped = Geometry.snapAngle(from: .zero, to: CGPoint(x: 10, y: 1))
        #expect(abs(snapped.y) < 0.0001)
        #expect(abs(snapped.length - CGPoint(x: 10, y: 1).length) < 0.0001)
        let diagonal = Geometry.snapAngle(from: .zero, to: CGPoint(x: 10, y: 9))
        #expect(abs(diagonal.x - diagonal.y) < 0.0001)
    }

    @Test(arguments: [
        (CGPoint(x: 5, y: 5), CGFloat(5)),
        (CGPoint(x: -3, y: 4), CGFloat(5)),
        (CGPoint(x: 13, y: 4), CGFloat(5)),
        (CGPoint(x: 7, y: 0), CGFloat(0)),
    ])
    func distanceToSegment(point: CGPoint, expected: CGFloat) {
        let distance = Geometry.distance(from: point, toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        #expect(abs(distance - expected) < 0.0001)
    }

    @Test func quadControlPassesThroughMidpoint() {
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 100, y: 0)
        let through = CGPoint(x: 50, y: 40)
        let control = Geometry.quadControl(start: start, end: end, through: through)
        let mid = Geometry.quadPoint(start, control, end, t: 0.5)
        #expect(mid.distance(to: through) < 0.0001)
    }

    struct HandleCase: Sendable, CustomTestStringConvertible {
        let handle: RectHandle
        let point: CGPoint
        let aspect: CGFloat?
        let expected: CGRect
        var testDescription: String { "\(handle) -> \(point) aspect \(aspect.map { "\($0)" } ?? "free")" }
    }

    @Test(arguments: [
        HandleCase(handle: .topLeft, point: CGPoint(x: 0, y: 0), aspect: nil, expected: CGRect(x: 0, y: 0, width: 110, height: 60)),
        HandleCase(handle: .right, point: CGPoint(x: 200, y: 999), aspect: nil, expected: CGRect(x: 10, y: 10, width: 190, height: 50)),
        HandleCase(handle: .bottom, point: CGPoint(x: 0, y: 5), aspect: nil, expected: CGRect(x: 10, y: 5, width: 100, height: 5)),
        HandleCase(handle: .bottomRight, point: CGPoint(x: 210, y: 0), aspect: 2, expected: CGRect(x: 10, y: -90, width: 200, height: 100)),
        HandleCase(handle: .right, point: CGPoint(x: 210, y: 0), aspect: 2, expected: CGRect(x: 10, y: -15, width: 200, height: 100)),
    ])
    func rectHandleResize(_ testCase: HandleCase) {
        let rect = CGRect(x: 10, y: 10, width: 100, height: 50)
        #expect(testCase.handle.resize(rect, to: testCase.point, aspect: testCase.aspect) == testCase.expected)
    }

    @Test func rectHandlePointsAndOpposites() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        #expect(RectHandle.bottomRight.point(in: rect) == CGPoint(x: 100, y: 50))
        #expect(RectHandle.top.point(in: rect) == CGPoint(x: 50, y: 0))
        for handle in RectHandle.allCases {
            #expect(handle.opposite.opposite == handle)
        }
    }

    @Test func snappedRectAlignsToPixels() {
        let rect = CGRect(x: 10.3, y: 4.74, width: 20.1, height: 9.9).snapped(toScale: 2)
        #expect(rect == CGRect(x: 10.5, y: 4.5, width: 20, height: 10))
    }

    @Test func constrainedRectStaysInside() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(CGRect(x: 90, y: -5, width: 20, height: 20).constrained(to: bounds) == CGRect(x: 80, y: 0, width: 20, height: 20))
        #expect(CGRect(x: 10, y: 10, width: 200, height: 20).constrained(to: bounds) == CGRect(x: 0, y: 10, width: 100, height: 20))
    }

    @Test func screenCoordinateConversions() {
        let space = ScreenCoordinates(primaryScreenHeight: 1000)
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        #expect(space.flip(rect) == CGRect(x: 10, y: 930, width: 100, height: 50))
        #expect(space.flip(space.flip(rect)) == rect)
        #expect(space.flip(CGPoint(x: 5, y: 10)) == CGPoint(x: 5, y: 990))

        let screen = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let local = CGRect(x: 100, y: 100, width: 200, height: 50)
        let global = ScreenCoordinates.cocoaRect(fromLocalTopLeft: local, screenFrame: screen)
        #expect(global == CGRect(x: 1540, y: 930, width: 200, height: 50))
        #expect(ScreenCoordinates.localTopLeft(fromCocoa: global, screenFrame: screen) == local)
        #expect(ScreenCoordinates.localTopLeft(fromCocoa: CGPoint(x: 1440, y: 1080), screenFrame: screen) == .zero)
    }
}
