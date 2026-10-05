// swift-tools-version:5.10
import PackageDescription

// VectorCore holds everything that is not presentation: domain models,
// the progression / analytics / insight engines, persistence and the
// service protocols (AI, purchases). It depends only on Foundation so it
// builds and tests on macOS, iOS and Linux CI alike.
let package = Package(
    name: "VectorCore",
    platforms: [.iOS(.v17), .macOS(.v14), .watchOS(.v10)],
    products: [
        .library(name: "VectorCore", targets: ["VectorCore"])
    ],
    targets: [
        .target(name: "VectorCore"),
        .testTarget(name: "VectorCoreTests", dependencies: ["VectorCore"])
    ]
)
