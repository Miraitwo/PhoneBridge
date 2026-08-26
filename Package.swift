// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "PhoneBridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PhoneBridge", targets: ["PhoneBridge"])
    ],
    targets: [
        .executableTarget(
            name: "PhoneBridge",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageCaptureCore"),
                .linkedFramework("Network"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "PhoneBridgeTests",
            dependencies: ["PhoneBridge"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
