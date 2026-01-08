// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsage",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClaudeUsage", targets: ["ClaudeUsage"])
    ],
    dependencies: [
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeUsage",
            dependencies: ["KeychainAccess"],
            path: "ClaudeUsage"
        )
    ]
)
