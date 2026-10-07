import CoreGraphics
import Foundation
import Testing
@testable import CuadroKit

struct RecordingAreaTests {
    private static let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private static let area = CGRect(x: 100, y: 100, width: 400, height: 300)

    struct HitCase: Sendable, CustomTestStringConvertible {
        let name: String
        let point: CGPoint
        let expected: RecordingArea.Hit
        var testDescription: String { name }
    }

    @Test(arguments: [
        HitCase(name: "top-left corner", point: CGPoint(x: 103, y: 98), expected: .handle(.topLeft)),
        HitCase(name: "right edge middle", point: CGPoint(x: 505, y: 250), expected: .handle(.right)),
        HitCase(name: "bottom edge middle", point: CGPoint(x: 300, y: 400), expected: .handle(.bottom)),
        HitCase(name: "inside", point: CGPoint(x: 200, y: 200), expected: .inside),
        HitCase(name: "on the edge away from handles", point: CGPoint(x: 100, y: 180), expected: .inside),
        HitCase(name: "outside", point: CGPoint(x: 50, y: 50), expected: .outside),
        HitCase(name: "just past a handle", point: CGPoint(x: 100, y: 89), expected: .outside),
    ])
    func hit(_ testCase: HitCase) {
        #expect(RecordingArea.hit(testCase.point, area: Self.area, handleRadius: 10) == testCase.expected)
    }

    @Test func handlesWinOnTinyAreas() {
        let tiny = CGRect(x: 100, y: 100, width: 12, height: 12)
        #expect(RecordingArea.hit(CGPoint(x: 106, y: 106), area: tiny, handleRadius: 10) != .inside)
    }

    struct MoveCase: Sendable, CustomTestStringConvertible {
        let name: String
        let delta: CGPoint
        let scale: CGFloat
        let expected: CGRect
        var testDescription: String { name }
    }

    @Test(arguments: [
        MoveCase(name: "plain move", delta: CGPoint(x: 30, y: -20), scale: 2, expected: CGRect(x: 130, y: 80, width: 400, height: 300)),
        MoveCase(name: "stops at the left and top edges", delta: CGPoint(x: -500, y: -500), scale: 2, expected: CGRect(x: 0, y: 0, width: 400, height: 300)),
        MoveCase(name: "stops at the right and bottom edges", delta: CGPoint(x: 900, y: 900), scale: 2, expected: CGRect(x: 600, y: 300, width: 400, height: 300)),
        MoveCase(name: "snaps to half points on Retina", delta: CGPoint(x: 10.3, y: 0.2), scale: 2, expected: CGRect(x: 110.5, y: 100, width: 400, height: 300)),
        MoveCase(name: "snaps to whole points at 1x", delta: CGPoint(x: 10.3, y: 0.6), scale: 1, expected: CGRect(x: 110, y: 101, width: 400, height: 300)),
    ])
    func moved(_ testCase: MoveCase) {
        #expect(RecordingArea.moved(Self.area, by: testCase.delta, within: Self.bounds, scale: testCase.scale) == testCase.expected)
    }

    struct ResizeCase: Sendable, CustomTestStringConvertible {
        let handle: RectHandle
        let point: CGPoint
        let expected: CGRect
        var testDescription: String { "\(handle) -> \(point)" }
    }

    @Test(arguments: [
        ResizeCase(handle: .bottomRight, point: CGPoint(x: 700, y: 500), expected: CGRect(x: 100, y: 100, width: 600, height: 400)),
        ResizeCase(handle: .topLeft, point: CGPoint(x: 50, y: 40), expected: CGRect(x: 50, y: 40, width: 450, height: 360)),
        ResizeCase(handle: .left, point: CGPoint(x: 150, y: 0), expected: CGRect(x: 150, y: 100, width: 350, height: 300)),
        ResizeCase(handle: .top, point: CGPoint(x: 999, y: 150), expected: CGRect(x: 100, y: 150, width: 400, height: 250)),
        ResizeCase(handle: .right, point: CGPoint(x: 5000, y: 250), expected: CGRect(x: 100, y: 100, width: 900, height: 300)),
        ResizeCase(handle: .topLeft, point: CGPoint(x: -50, y: -50), expected: CGRect(x: 0, y: 0, width: 500, height: 400)),
        // Dragging past the opposite edge stops at the minimum size instead of flipping.
        ResizeCase(handle: .right, point: CGPoint(x: 0, y: 250), expected: CGRect(x: 100, y: 100, width: 40, height: 300)),
        ResizeCase(handle: .bottomLeft, point: CGPoint(x: 900, y: 0), expected: CGRect(x: 460, y: 100, width: 40, height: 40)),
        ResizeCase(handle: .bottom, point: CGPoint(x: 0, y: 300.3), expected: CGRect(x: 100, y: 100, width: 400, height: 200.5)),
    ])
    func resized(_ testCase: ResizeCase) {
        #expect(RecordingArea.resized(Self.area, handle: testCase.handle, to: testCase.point, within: Self.bounds, scale: 2) == testCase.expected)
    }

    @Test func drawnNeedsTheMinimumSize() {
        #expect(RecordingArea.drawn(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 30, y: 300), within: Self.bounds, scale: 2) == nil)
        #expect(RecordingArea.drawn(from: CGPoint(x: 300, y: 200), to: CGPoint(x: 100, y: 100), within: Self.bounds, scale: 2) == CGRect(x: 100, y: 100, width: 200, height: 100))
        #expect(RecordingArea.drawn(from: CGPoint(x: 900, y: 500), to: CGPoint(x: 1200, y: 900), within: Self.bounds, scale: 2) == CGRect(x: 900, y: 500, width: 100, height: 100))
    }

    struct ControlsCase: Sendable, CustomTestStringConvertible {
        let name: String
        let area: CGRect
        let expected: CGPoint
        var testDescription: String { name }
    }

    // Cocoa y-up: a 1000 × 600 screen, controls 200 × 60.
    @Test(arguments: [
        ControlsCase(name: "below the area", area: CGRect(x: 300, y: 200, width: 400, height: 300), expected: CGPoint(x: 400, y: 130)),
        ControlsCase(name: "above when the area touches the bottom", area: CGRect(x: 300, y: 20, width: 400, height: 300), expected: CGPoint(x: 400, y: 330)),
        ControlsCase(name: "inside for a full-screen area", area: CGRect(x: 0, y: 0, width: 1000, height: 600), expected: CGPoint(x: 400, y: 12)),
        ControlsCase(name: "kept on screen horizontally", area: CGRect(x: -50, y: 200, width: 100, height: 100), expected: CGPoint(x: 8, y: 130)),
    ])
    func controlsOrigin(_ testCase: ControlsCase) {
        let origin = RecordingArea.controlsOrigin(for: testCase.area, controlsSize: CGSize(width: 200, height: 60), screen: Self.bounds)
        #expect(origin == testCase.expected)
    }

    @Test(arguments: [
        (CGRect(x: 0, y: 0, width: 400, height: 300), CGFloat(2), 800, 600),
        (CGRect(x: 0, y: 0, width: 400.5, height: 300.5), CGFloat(2), 800, 600),
        (CGRect(x: 0, y: 0, width: 333, height: 201), CGFloat(1), 332, 200),
        (CGRect(x: 0, y: 0, width: 0.4, height: 0.4), CGFloat(1), 2, 2),
    ])
    func pixelSize(area: CGRect, scale: CGFloat, width: Int, height: Int) {
        let size = RecordingArea.pixelSize(of: area, scale: scale)
        #expect(size.width == width)
        #expect(size.height == height)
    }

    @Test func cropOriginStaysInsideTheFrame() {
        let frame = CGSize(width: 2000, height: 1200)
        let crop = CGSize(width: 800, height: 600)
        #expect(RecordingArea.cropOrigin(of: Self.area, scale: 2, cropSize: crop, frameSize: frame) == CGPoint(x: 200, y: 200))
        // An odd-sized area loses its last pixel to the even crop, which must still fit.
        let edge = CGRect(x: 599.5, y: 300, width: 400.5, height: 300)
        #expect(RecordingArea.cropOrigin(of: edge, scale: 2, cropSize: crop, frameSize: frame) == CGPoint(x: 1199, y: 600))
        #expect(RecordingArea.cropOrigin(of: CGRect(x: 950, y: 0, width: 400, height: 300), scale: 2, cropSize: crop, frameSize: frame) == CGPoint(x: 1200, y: 0))
    }

    struct SmoothingCase: Sendable, CustomTestStringConvertible {
        let name: String
        let current: CGPoint
        let elapsed: TimeInterval
        let expected: CGPoint
        var testDescription: String { name }
    }

    @Test(arguments: [
        SmoothingCase(name: "one time constant closes 63%", current: .zero, elapsed: 0.1, expected: CGPoint(x: 63.212, y: 31.606)),
        SmoothingCase(name: "no time, no move", current: .zero, elapsed: 0, expected: .zero),
        SmoothingCase(name: "snaps when close", current: CGPoint(x: 99.7, y: 49.8), elapsed: 0.001, expected: CGPoint(x: 100, y: 50)),
        SmoothingCase(name: "a long pause arrives", current: .zero, elapsed: 5, expected: CGPoint(x: 100, y: 50)),
    ])
    func smoothing(_ testCase: SmoothingCase) {
        let next = Smoothing.approach(testCase.current, to: CGPoint(x: 100, y: 50), elapsed: testCase.elapsed, timeConstant: 0.1, snapDistance: 0.5)
        #expect(next.distance(to: testCase.expected) < 0.001)
    }

    @Test func smoothingNeverOvershoots() {
        var point = CGPoint.zero
        let target = CGPoint(x: 400, y: -120)
        var previous = point.distance(to: target)
        for _ in 0..<120 {
            point = Smoothing.approach(point, to: target, elapsed: 1.0 / 60, timeConstant: 0.08, snapDistance: 0.5)
            let distance = point.distance(to: target)
            #expect(distance <= previous)
            previous = distance
        }
        #expect(point == target)
    }
}
