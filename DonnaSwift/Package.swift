// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DonnaSwift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DonnaMacApp", targets: ["DonnaMacApp"])
    ],
    targets: [
        .executableTarget(
            name: "DonnaMacApp",
            path: "Sources/DonnaMacApp"
        )
    ]
)
