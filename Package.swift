// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Spool",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SpoolCore", targets: ["SpoolCore"]),
        .executable(name: "spool-statusline", targets: ["spool-statusline"]),
    ],
    targets: [
        .target(name: "SpoolCore"),
        .executableTarget(name: "spool-statusline", dependencies: ["SpoolCore"]),
        .executableTarget(name: "Spool", dependencies: ["SpoolCore"]),
        .testTarget(
            name: "SpoolCoreTests",
            dependencies: ["SpoolCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
