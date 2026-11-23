// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Splitroute",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The app owns the settings database; GRDB is its SQLite layer.
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.9.0"),
    ],
    targets: [
        .executableTarget(name: "Splitroute", dependencies: ["Design", .product(name: "GRDB", package: "GRDB.swift")], path: "Sources/Splitroute"),
        .testTarget(name: "SplitrouteTests", dependencies: ["Splitroute"], path: "Tests/SplitrouteTests"),
        // The redesign: tokens, fonts and components (Design), shown on fake data
        // (DesignPreview) until the real pages move over.
        .target(name: "Design", path: "Sources/Design", resources: [.copy("Resources/Fonts")]),
        .executableTarget(name: "DesignPreview", dependencies: ["Design"], path: "Sources/DesignPreview"),
        .testTarget(name: "DesignTests", dependencies: ["Design"], path: "Tests/DesignTests"),
    ]
)
