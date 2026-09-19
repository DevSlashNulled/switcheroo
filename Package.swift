// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Switcheroo",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Switcheroo", targets: ["Switcheroo"])],
    targets: [
        .target(name: "SwitcherooCore"),
        .executableTarget(name: "Switcheroo", dependencies: ["SwitcherooCore"]),
        .testTarget(name: "SwitcherooCoreTests", dependencies: ["SwitcherooCore"]),
        .testTarget(name: "SwitcherooAppTests", dependencies: ["Switcheroo", "SwitcherooCore"]),
    ]
)
