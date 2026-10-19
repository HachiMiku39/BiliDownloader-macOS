// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BiliMac",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "BiliMac", targets: ["BiliMac"])],
    targets: [
        .executableTarget(name: "BiliMac"),
        .testTarget(name: "BiliMacTests", dependencies: ["BiliMac"])
    ],
    swiftLanguageModes: [.v5]
)
