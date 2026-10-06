import Foundation
import Testing
@testable import CuadroKit

struct FileNameTemplateTests {
    static let context = FileNameTemplate.Context(
        date: Date(timeIntervalSince1970: 1_791_122_709), // 2026-10-04 14:05:09 UTC
        width: 800,
        height: 600,
        appName: "Safari",
        counter: 7,
        timeZone: TimeZone(identifier: "UTC")!
    )

    @Test(arguments: [
        (FileNameTemplate.defaultTemplate, "Screenshot 2026-10-04 at 14.05.09"),
        ("{w}x{h}", "800x600"),
        ("{app} {n}", "Safari 7"),
        ("{yyyy}{MM}{dd}-{HH}{mm}{ss}", "20261004-140509"),
        ("{yy}", "26"),
        ("keep {unknown} token", "keep {unknown} token"),
        ("open {date", "open {date"),
        ("a/b:c {date}", "a-b-c 2026-10-04"),
    ])
    func rendersTokens(template: String, expected: String) {
        #expect(FileNameTemplate.render(template, context: Self.context) == expected)
    }

    @Test(arguments: [
        ("a/b:c", "a-b-c"),
        ("   ", "Screenshot"),
        (".hidden", "hidden"),
        ("too    many   spaces", "too many spaces"),
        ("tab\there", "tab here"),
    ])
    func sanitizes(input: String, expected: String) {
        #expect(FileNameTemplate.sanitize(input) == expected)
    }

    @Test func findsUniqueName() {
        let directory = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
        let existing: Set<String> = ["a.png", "a (2).png"]
        let url = FileNameTemplate.uniqueFileURL(directory: directory, baseName: "a", pathExtension: "png") {
            existing.contains($0.lastPathComponent)
        }
        #expect(url.lastPathComponent == "a (3).png")

        let fresh = FileNameTemplate.uniqueFileURL(directory: directory, baseName: "b", pathExtension: "jpg") { _ in false }
        #expect(fresh.lastPathComponent == "b.jpg")
    }
}
