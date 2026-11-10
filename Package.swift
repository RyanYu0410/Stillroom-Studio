// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stillroom",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Stillroom", targets: ["Stillroom"])],
    targets: [
        .executableTarget(name: "Stillroom"),
        .testTarget(name: "StillroomTests", dependencies: ["Stillroom"])
    ]
)
