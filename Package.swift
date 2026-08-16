// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftScraper",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "swift-scraper", targets: ["SwiftScraperCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jaredhowland/html-to-markdown-swift.git", from: "0.9.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.11.2"),
        .package(url: "https://github.com/JohnSundell/Ink.git", from: "0.6.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.66.0"),
    ],
    targets: [
        .target(
            name: "SwiftScraperCore",
            dependencies: [
                .product(name: "HTMLToMarkdown", package: "html-to-markdown-swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                "SwiftSoup",
                "Ink",
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "SwiftScraperCLI",
            dependencies: ["SwiftScraperCore"]
        ),
        .testTarget(
            name: "SwiftScraperCoreTests",
            dependencies: ["SwiftScraperCore"]
        ),
    ]
)
