// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TailIME",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TailIMECore", targets: ["TailIMECore"]),
        .executable(name: "TailIME", targets: ["TailIMEApp"]),
        .executable(name: "tailime-ctl", targets: ["tailime-ctl"]),
    ],
    targets: [
        .target(
            name: "CSystemBridge",
            path: "Sources/CSystemBridge",
            publicHeadersPath: "include",
            cSettings: [
                .define("__APPLE_USE_RFC_3542", to: "1"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "TailIMECore",
            dependencies: ["CSystemBridge"],
            path: "Sources/TailIMECore",
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "TailIMEApp",
            dependencies: ["TailIMECore", "CSystemBridge"],
            path: "Sources/TailIMEApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "tailime-ctl",
            dependencies: ["TailIMECore"],
            path: "Sources/tailime-ctl",
            linkerSettings: [
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "tailime-test",
            dependencies: ["TailIMECore", "CSystemBridge"],
            path: "Tests/TailIMETestRunner"
        ),
    ],
    swiftLanguageModes: [.v5]
)
