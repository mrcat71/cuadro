import OSLog

/// Unified logging; read with `log show --predicate 'subsystem == "io.github.mrcat71.cuadro"'`.
enum Log {
    nonisolated static let subsystem = "io.github.mrcat71.cuadro"
    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    nonisolated static let capture = Logger(subsystem: subsystem, category: "capture")
    nonisolated static let editor = Logger(subsystem: subsystem, category: "editor")
    nonisolated static let output = Logger(subsystem: subsystem, category: "output")
    nonisolated static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
}
