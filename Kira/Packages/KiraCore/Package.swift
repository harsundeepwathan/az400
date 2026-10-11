// swift-tools-version: 6.0
// KiraCore — platform-independent domain logic for Kira.
// Contains no UIKit/SwiftUI/SwiftData code so it builds and tests on macOS, iOS and Linux CI.
import PackageDescription

let package = Package(
    name: "KiraCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "KiraCore", targets: ["KiraCore"])
    ],
    targets: [
        .target(
            name: "KiraCore",
            swiftSettings: [.swiftLanguageMode(.v5), .enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "KiraCoreTests",
            dependencies: ["KiraCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
