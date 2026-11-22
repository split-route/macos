// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Splitroute",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Splitroute", dependencies: ["Design"], path: "Sources/Splitroute"),
        // The redesign: tokens, fonts and components (Design), shown on fake data
        // (DesignPreview) until the real pages move over.
        .target(name: "Design", path: "Sources/Design", resources: [.copy("Resources/Fonts")]),
        .executableTarget(name: "DesignPreview", dependencies: ["Design"], path: "Sources/DesignPreview"),
        .testTarget(name: "DesignTests", dependencies: ["Design"], path: "Tests/DesignTests"),
    ]
)
