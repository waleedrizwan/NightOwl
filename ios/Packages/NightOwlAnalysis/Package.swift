// swift-tools-version: 5.9
import PackageDescription

// The night analysis (analysis/analyze.py) in Swift, so the iPhone can do it
// with no Mac. Builds for macOS too: owl-analyze runs it on a night folder and
// prints the same JSON the app reads, to check it against the Python reports.
let package = Package(
    name: "NightOwlAnalysis",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "NightOwlAnalysis", targets: ["NightOwlAnalysis"]),
        .executable(name: "owl-analyze", targets: ["owl-analyze"]),
    ],
    targets: [
        .target(
            name: "NightOwlAnalysis",
            resources: [
                // symlinks to model/, the copy analyze.py uses
                .copy("Resources/YAMNet.mlmodelc"),
                .copy("Resources/yamnet_class_map.csv"),
            ]),
        .executableTarget(name: "owl-analyze", dependencies: ["NightOwlAnalysis"]),
        .testTarget(name: "NightOwlAnalysisTests", dependencies: ["NightOwlAnalysis"]),
    ]
)
