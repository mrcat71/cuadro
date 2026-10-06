// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Cuadro",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Cuadro", targets: ["Cuadro"]),
        .library(name: "CuadroKit", targets: ["CuadroKit"]),
    ],
    targets: [
        // Pure logic and rendering: geometry, annotations, stitching, colors, file naming.
        // No AppKit, so everything here is unit-testable without a window server.
        .target(name: "CuadroKit"),
        // The menu bar app: AppKit lifecycle, SwiftUI views, ScreenCaptureKit, Vision.
        .executableTarget(
            name: "Cuadro",
            dependencies: ["CuadroKit"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Renders the app icon PNG set; the Makefile turns it into AppIcon.icns.
        .executableTarget(name: "cuadro-icon"),
        .testTarget(name: "CuadroKitTests", dependencies: ["CuadroKit"]),
    ]
)
