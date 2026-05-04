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
    ],
    targets: [
        .target(
            name: "SwiftScraperCore",
            dependencies: [
                .product(name: "HTMLToMarkdown", package: "html-to-markdown-swift"),
                "SwiftSoup",
                "Ink",
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
