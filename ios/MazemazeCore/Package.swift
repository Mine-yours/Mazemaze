// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MazemazeCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "MazemazeCore", targets: ["MazemazeCore"])],
    targets: [
        .target(name: "MazemazeCore"),
        .testTarget(name: "MazemazeCoreTests", dependencies: ["MazemazeCore"]),
    ]
)
