// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeChatNASMount",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WeChatNASMount", targets: ["WeChatNASMount"])],
    targets: [.executableTarget(name: "WeChatNASMount")]
)
