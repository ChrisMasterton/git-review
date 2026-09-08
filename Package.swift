// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitReview",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GitReview", targets: ["GitReview"])
    ],
    targets: [
        .target(name: "GitReviewCore"),
        .executableTarget(name: "GitReview", dependencies: ["GitReviewCore"]),
        .testTarget(name: "GitReviewCoreTests", dependencies: ["GitReviewCore"]),
        .testTarget(name: "GitReviewTests", dependencies: ["GitReview"])
    ]
)
