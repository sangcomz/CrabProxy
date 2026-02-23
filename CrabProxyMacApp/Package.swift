// swift-tools-version: 6.2
import PackageDescription

let rustDebugLibDir = "../crab-mitm/target/debug"
let rustReleaseLibDir = "../crab-mitm/target/release"

let package = Package(
    name: "CrabProxyMacApp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "CrabProxyMacApp", targets: ["CrabProxyMacApp"]),
    ],
    targets: [
        .target(
            name: "CCrabMitm",
            path: "Sources/CCrabMitm",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "CrabProxyMacApp",
            dependencies: [
                "CCrabMitm",
            ],
            path: "Sources/CrabProxyMacApp",
            resources: [
                .process("Assets.xcassets"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", rustDebugLibDir,
                    "-L", rustReleaseLibDir,
                    "-lcrab_mitm",
                ]),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
                .linkedLibrary("iconv"),
            ]
        ),
        .executableTarget(
            name: "CrabProxyHelper",
            path: "Sources/CrabProxyHelper"
        ),
        .testTarget(
            name: "CrabProxyMacAppTests",
            dependencies: ["CrabProxyMacApp"],
            path: "Tests/CrabProxyMacAppTests"
        ),
    ]
)
