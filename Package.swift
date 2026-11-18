// swift-tools-version: 5.10
import Foundation
import PackageDescription

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "AudioMatrixHub",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AudioMatrixCore", targets: ["AudioMatrixCore"]),
        .executable(name: "AudioMatrixHub", targets: ["AudioMatrixHub"]),
        .executable(name: "audiomatrix", targets: ["AudioMatrixCLI"])
    ],
    targets: [
        .target(
            name: "CAudioMatrixRust",
            path: "Sources/CAudioMatrixRust"
        ),
        .target(
            name: "AudioMatrixCore",
            dependencies: ["CAudioMatrixRust"],
            path: "Sources/AudioMatrixCore",
            linkerSettings: [
                .unsafeFlags(["\(packageDir)/rust-core/target/release/libaudiomatrix_rust_core.a"]),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit")
            ]
        ),
        .executableTarget(
            name: "AudioMatrixHub",
            dependencies: ["AudioMatrixCore"],
            path: "Sources/AudioMatrixHub"
        ),
        .executableTarget(
            name: "AudioMatrixCLI",
            dependencies: ["AudioMatrixCore"],
            path: "Sources/AudioMatrixCLI"
        )
    ]
)
