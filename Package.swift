// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrainingPlanKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "TrainingPlanKit", targets: ["TrainingPlanKit"]),
    ],
    targets: [
        .target(
            name: "TrainingPlanKit",
            resources: [
                .copy("Catalog/sample_catalog.json"),
            ]
        ),
    ]
)
