import CoreGraphics
import Testing
@testable import CuadroKit

struct TextAssemblerTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let fragments: [TextFragment]
        let expected: String
        var testDescription: String { name }
    }

    @Test(arguments: [
        Case(
            name: "same line out of order",
            fragments: [
                TextFragment(text: "world", box: CGRect(x: 60, y: 10, width: 40, height: 12)),
                TextFragment(text: "Hello", box: CGRect(x: 10, y: 11, width: 40, height: 12)),
            ],
            expected: "Hello world"
        ),
        Case(
            name: "two lines",
            fragments: [
                TextFragment(text: "second", box: CGRect(x: 10, y: 26, width: 40, height: 12)),
                TextFragment(text: "first", box: CGRect(x: 10, y: 10, width: 40, height: 12)),
            ],
            expected: "first\nsecond"
        ),
        Case(
            name: "paragraph gap",
            fragments: [
                TextFragment(text: "Title", box: CGRect(x: 10, y: 10, width: 40, height: 12)),
                TextFragment(text: "Body", box: CGRect(x: 10, y: 60, width: 40, height: 12)),
            ],
            expected: "Title\n\nBody"
        ),
        Case(
            name: "collapses spaces",
            fragments: [TextFragment(text: "  a   b  ", box: CGRect(x: 0, y: 0, width: 10, height: 10))],
            expected: "a b"
        ),
        Case(name: "empty", fragments: [], expected: ""),
    ])
    func assembles(_ testCase: Case) {
        #expect(TextAssembler.assemble(testCase.fragments) == testCase.expected)
    }
}
