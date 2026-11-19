import CoreGraphics
import Testing
@testable import CuadroKit

struct WindowCaptureTests {
    struct IsolationCase: Sendable, CustomTestStringConvertible {
        let name: String
        let frame: CGRect
        let filterSize: CGSize
        let sameAppFrames: [CGRect]
        let expected: Bool
        var testDescription: String { name }
    }

    static let settings = CGRect(x: 100, y: 50, width: 600, height: 880)
    static let sheet = CGRect(x: 220, y: 370, width: 370, height: 135)

    @Test(arguments: [
        IsolationCase(name: "plain window", frame: settings, filterSize: settings.size, sameAppFrames: [], expected: false),
        IsolationCase(name: "sheet inside its parent", frame: sheet, filterSize: sheet.size, sameAppFrames: [settings], expected: true),
        IsolationCase(name: "filter wider than the window", frame: sheet, filterSize: settings.size, sameAppFrames: [], expected: true),
        IsolationCase(name: "within the 1 pt tolerance", frame: settings, filterSize: CGSize(width: 600.5, height: 879.5), sameAppFrames: [], expected: false),
        IsolationCase(name: "parent picked, child inside it", frame: settings, filterSize: settings.size, sameAppFrames: [sheet], expected: false),
        IsolationCase(name: "overlapping, not inside", frame: sheet, filterSize: sheet.size, sameAppFrames: [CGRect(x: 300, y: 300, width: 600, height: 600)], expected: false),
        IsolationCase(name: "same frame twice", frame: settings, filterSize: settings.size, sameAppFrames: [settings], expected: false),
    ])
    func needsIsolation(_ testCase: IsolationCase) {
        let result = WindowCapture.needsIsolation(frame: testCase.frame, filterSize: testCase.filterSize, sameAppFrames: testCase.sameAppFrames)
        #expect(result == testCase.expected)
    }

    @Test func displayShowingMostOfTheWindow() {
        let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 0, width: 2560, height: 1440)]
        #expect(WindowCapture.display(for: CGRect(x: 1400, y: 100, width: 400, height: 300), among: displays) == 1)
        #expect(WindowCapture.display(for: CGRect(x: 1300, y: 100, width: 400, height: 300), among: displays) == 0)
        #expect(WindowCapture.display(for: CGRect(x: 5000, y: 100, width: 400, height: 300), among: displays) == nil)
    }

    @Test func sourceRectIsDisplayLocalAndKeptOnTheDisplay() {
        let display = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        #expect(WindowCapture.sourceRect(frame: CGRect(x: 1612, y: 200, width: 300, height: 100), margin: 0, displayBounds: display)
            == CGRect(x: 100, y: 200, width: 300, height: 100))
        #expect(WindowCapture.sourceRect(frame: CGRect(x: 1552, y: 40, width: 300, height: 100), margin: 120, displayBounds: display)
            == CGRect(x: 0, y: 0, width: 460, height: 260))
        #expect(WindowCapture.sourceRect(frame: CGRect(x: 0, y: 0, width: 300, height: 100), margin: 0, displayBounds: display) == nil)
    }
}
