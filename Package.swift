// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Cuadro",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Cuadro", targets: ["Cuadro"]),
        .library(name: "CuadroKit", targets: ["CuadroKit"]),
    ],
    dependencies: [
        // In-app updates; its bin/ tools (generate_keys, sign_update, generate_appcast) also sign releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure logic and rendering: geometry, annotations, stitching, colors, file naming, AAC settings.
        // No AppKit, so everything here is unit-testable without a window server.
        .target(name: "CuadroKit"),
        // The menu bar app: AppKit lifecycle, SwiftUI views, ScreenCaptureKit, Vision, Sparkle.
        .executableTarget(
            name: "Cuadro",
            dependencies: ["CuadroKit", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        // Renders the app icon PNG set; the Makefile turns it into AppIcon.icns.
        .executableTarget(name: "cuadro-icon"),
        .testTarget(name: "CuadroKitTests", dependencies: ["CuadroKit"]),
    ]
)
