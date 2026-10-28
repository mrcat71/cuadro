import CoreGraphics
import Foundation
import Testing
@testable import CuadroKit

struct CameraBubbleTests {
    private static let area = CGRect(x: 100, y: 50, width: 800, height: 450)

    struct DiameterCase: Sendable, CustomTestStringConvertible {
        let name: String
        let area: CGSize
        let expected: CGFloat?
        var testDescription: String { name }
    }

    @Test(arguments: [
        DiameterCase(name: "full size in a large area", area: CGSize(width: 1280, height: 720), expected: 180),
        DiameterCase(name: "full size at exactly twice it", area: CGSize(width: 360, height: 900), expected: 180),
        DiameterCase(name: "half the shorter side at most", area: CGSize(width: 800, height: 300), expected: 150),
        DiameterCase(name: "half of an odd side rounds down", area: CGSize(width: 800, height: 301), expected: 150),
        DiameterCase(name: "still at the minimum", area: CGSize(width: 80, height: 400), expected: 40),
        DiameterCase(name: "too small an area", area: CGSize(width: 79, height: 400), expected: nil),
    ])
    func diameter(_ testCase: DiameterCase) {
        #expect(CameraBubbleLayout.diameter(in: testCase.area) == testCase.expected)
    }

    struct FrameCase: Sendable, CustomTestStringConvertible {
        let name: String
        let anchor: CGPoint
        let area: CGRect
        let expected: CGRect
        var testDescription: String { name }
    }

    @Test(arguments: [
        FrameCase(name: "bottom-left by default", anchor: CameraBubbleLayout.defaultAnchor, area: area, expected: CGRect(x: 116, y: 304, width: 180, height: 180)),
        FrameCase(name: "top-left", anchor: CGPoint(x: 0, y: 0), area: area, expected: CGRect(x: 116, y: 66, width: 180, height: 180)),
        FrameCase(name: "bottom-right", anchor: CGPoint(x: 1, y: 1), area: area, expected: CGRect(x: 704, y: 304, width: 180, height: 180)),
        FrameCase(name: "middle", anchor: CGPoint(x: 0.5, y: 0.5), area: area, expected: CGRect(x: 410, y: 185, width: 180, height: 180)),
        FrameCase(name: "anchors outside 0 to 1 stay inside", anchor: CGPoint(x: -3, y: 7), area: area, expected: CGRect(x: 116, y: 304, width: 180, height: 180)),
        FrameCase(name: "centered without room for the margins", anchor: CGPoint(x: 1, y: 1), area: CGRect(x: 0, y: 0, width: 200, height: 360), expected: CGRect(x: 10, y: 164, width: 180, height: 180)),
    ])
    func frame(_ testCase: FrameCase) {
        #expect(CameraBubbleLayout.frame(anchor: testCase.anchor, diameter: 180, in: testCase.area) == testCase.expected)
    }

    struct AnchorCase: Sendable, CustomTestStringConvertible {
        let name: String
        let origin: CGPoint
        let expected: CGPoint
        var testDescription: String { name }
    }

    @Test(arguments: [
        AnchorCase(name: "top-left corner of the room", origin: CGPoint(x: 116, y: 66), expected: CGPoint(x: 0, y: 0)),
        AnchorCase(name: "bottom-right corner of the room", origin: CGPoint(x: 704, y: 304), expected: CGPoint(x: 1, y: 1)),
        AnchorCase(name: "a quarter across, halfway down", origin: CGPoint(x: 263, y: 185), expected: CGPoint(x: 0.25, y: 0.5)),
        AnchorCase(name: "dragged past the edges", origin: CGPoint(x: -500, y: 2000), expected: CGPoint(x: 0, y: 1)),
    ])
    func anchor(_ testCase: AnchorCase) {
        #expect(CameraBubbleLayout.anchor(origin: testCase.origin, diameter: 180, in: Self.area) == testCase.expected)
    }

    @Test func anchorWithoutRoomIsTheMiddle() {
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 200)
        #expect(CameraBubbleLayout.anchor(origin: CGPoint(x: 10, y: 10), diameter: 180, in: narrow) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func bubbleKeepsItsCornerWhenTheAreaChanges() {
        let anchor = CameraBubbleLayout.anchor(origin: CGPoint(x: 704, y: 304), diameter: 180, in: Self.area)
        let moved = CGRect(x: 300, y: 200, width: 640, height: 360)
        #expect(CameraBubbleLayout.frame(anchor: anchor, diameter: 180, in: moved) == CGRect(x: 744, y: 364, width: 180, height: 180))
    }
}
