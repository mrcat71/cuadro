import Foundation

/// Expands file name templates such as `Screenshot {date} at {time}`.
public enum FileNameTemplate {
    public static let defaultTemplate = "Screenshot {date} at {time}"

    public struct Context: Sendable {
        public var date: Date
        public var width: Int
        public var height: Int
        public var appName: String?
        public var counter: Int
        public var timeZone: TimeZone

        public init(date: Date = Date(), width: Int = 0, height: Int = 0, appName: String? = nil, counter: Int = 1, timeZone: TimeZone = .current) {
            self.date = date
            self.width = width
            self.height = height
            self.appName = appName
            self.counter = counter
            self.timeZone = timeZone
        }
    }

    /// Supported tokens with a short description, for the settings UI.
    public static let tokens: [(token: String, meaning: String)] = [
        ("{date}", "2026-10-04"),
        ("{time}", "14.05.09"),
        ("{yyyy}", "year"),
        ("{MM}", "month"),
        ("{dd}", "day"),
        ("{HH}", "hour"),
        ("{mm}", "minute"),
        ("{ss}", "second"),
        ("{w}", "width in px"),
        ("{h}", "height in px"),
        ("{app}", "frontmost app"),
        ("{n}", "counter"),
    ]

    public static func render(_ template: String, context: Context) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: context.date)
        func pad(_ value: Int?, _ width: Int = 2) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let values: [String: String] = [
            "date": "\(pad(parts.year, 4))-\(pad(parts.month))-\(pad(parts.day))",
            "time": "\(pad(parts.hour)).\(pad(parts.minute)).\(pad(parts.second))",
            "yyyy": pad(parts.year, 4),
            "yy": String(pad(parts.year, 4).suffix(2)),
            "MM": pad(parts.month),
            "dd": pad(parts.day),
            "HH": pad(parts.hour),
            "mm": pad(parts.minute),
            "ss": pad(parts.second),
            "w": String(context.width),
            "h": String(context.height),
            "app": context.appName ?? "",
            "n": String(context.counter),
        ]

        var result = ""
        var remainder = Substring(template)
        while let open = remainder.firstIndex(of: "{") {
            result += remainder[..<open]
            guard let close = remainder[open...].firstIndex(of: "}") else {
                remainder = remainder[open...]
                break
            }
            let name = String(remainder[remainder.index(after: open)..<close])
            result += values[name] ?? String(remainder[open...close])
            remainder = remainder[remainder.index(after: close)...]
        }
        result += remainder
        return sanitize(result)
    }

    /// Makes a string safe to use as a file name.
    public static func sanitize(_ name: String) -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            return Character(scalar)
        })
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 200 { cleaned = String(cleaned.prefix(200)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Screenshot" : cleaned
    }

    /// First URL `<base>.<ext>`, `<base> (2).<ext>`, ... that does not exist yet.
    public static func uniqueFileURL(directory: URL, baseName: String, pathExtension: String, fileExists: (URL) -> Bool) -> URL {
        let first = directory.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        guard fileExists(first) else { return first }
        for index in 2...10_000 {
            let candidate = directory.appendingPathComponent("\(baseName) (\(index))").appendingPathExtension(pathExtension)
            if !fileExists(candidate) { return candidate }
        }
        return directory.appendingPathComponent("\(baseName) \(UUID().uuidString)").appendingPathExtension(pathExtension)
    }
}
