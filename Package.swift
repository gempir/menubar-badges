// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenubarBadges",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MenubarBadgesCore",
            targets: ["MenubarBadgesCore"]
        ),
        .executable(
            name: "MenubarBadges",
            targets: ["MenubarBadges"]
        )
    ],
    targets: [
        .target(
            name: "MenubarBadgesCore",
            path: "Sources/MenubarBadgesCore"
        ),
        .executableTarget(
            name: "MenubarBadges",
            dependencies: ["MenubarBadgesCore"],
            path: "Sources/MenubarBadges",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "MenubarBadgesCoreTests",
            dependencies: ["MenubarBadgesCore"],
            path: "Tests/MenubarBadgesCoreTests"
        )
    ]
)
