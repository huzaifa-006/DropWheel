// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DropWheel",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DropWheel", targets: ["DropWheel"]),
        .executable(name: "dropwheel-selftest", targets: ["dropwheel-selftest"]),
    ],
    targets: [
        .target(name: "DropWheelCore"),
        .executableTarget(name: "DropWheel", dependencies: ["DropWheelCore"]),
        .executableTarget(name: "dropwheel-selftest", dependencies: ["DropWheelCore"]),
    ]
)
