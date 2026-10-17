// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StageFit",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "StageFit", targets: ["StageFit"])],
    targets: [
        .target(name: "StageFitCore"),
        .executableTarget(name: "StageFit", dependencies: ["StageFitCore"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ApplicationServices"),
                             .linkedFramework("Carbon")]),
        .testTarget(name: "StageFitCoreTests", dependencies: ["StageFitCore"])
    ],
    swiftLanguageModes: [.v6]
)
