// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MikeMailCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MailDomain", targets: ["MailDomain"]),
        .library(name: "MailApplication", targets: ["MailApplication"]),
        .library(name: "MailDemo", targets: ["MailDemo"]),
        .library(name: "MailPersistence", targets: ["MailPersistence"]),
        .library(name: "MailSecurity", targets: ["MailSecurity"]),
        .library(name: "MailIMAP", targets: ["MailIMAP"]),
        .library(name: "MailGoogle", targets: ["MailGoogle"]),
        .library(name: "MailRendering", targets: ["MailRendering"]),
        .library(name: "MailMCP", targets: ["MailMCP"])
    ],
    dependencies: [.package(path: "../../Vendor/GRDB"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio", exact: "2.105.0"),
        .package(url: "https://github.com/openid/AppAuth-iOS.git", exact: "3.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3"),
        .package(url: "https://github.com/Cocoanetics/SwiftMail.git", revision: "88c45cbd31b347b373f7c87e197be63eb95efbc2"),
        .package(url: "https://github.com/apple/swift-nio-imap", revision: "14ad3887dab9ca5aba38ee0ace18fddf40e9491f"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.11.0")],
    targets: [
        .target(name: "MailDomain"),
        .target(name: "MailRendering", dependencies: [.product(name: "SwiftSoup", package: "SwiftSoup")]),
        .target(name: "MailApplication", dependencies: ["MailDomain", "MailRendering"]),
        .target(name: "MailMCP", dependencies: ["MailDomain", "MailApplication", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log"), .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio")]),
        .testTarget(name: "MailMCPTests", dependencies: ["MailMCP", "MailDemo", "MailPersistence"]),
        .target(name: "MailGoogle", dependencies: ["MailDomain", "MailApplication", "MailIMAP", .product(name: "AppAuth", package: "AppAuth-iOS"), .product(name: "SwiftMail", package: "SwiftMail")]),
        .target(name: "MailDemo", dependencies: ["MailDomain", "MailApplication"]),
        .target(name: "MailIMAP", dependencies: ["MailDomain", "MailApplication", .product(name: "SwiftMail", package: "SwiftMail"),
            .product(name: "NIOIMAP", package: "swift-nio-imap"), .product(name: "Logging", package: "swift-log")]),
        .target(name: "MailSecurity", dependencies: ["MailDomain", "MailApplication"]),
        .target(name: "MailPersistence", dependencies: ["MailDomain", "MailApplication", "MailSecurity", .product(name: "GRDB", package: "GRDB")]),
        .testTarget(name: "MailRenderingTests", dependencies: ["MailRendering"]),
        .testTarget(name: "MailGoogleTests", dependencies: ["MailGoogle", "MailPersistence", "MailDemo"]),
        .testTarget(name: "MikeMailCoreTests", dependencies: ["MailDomain", "MailApplication", "MailDemo"]),
        .testTarget(name: "MailPersistenceTests", dependencies: ["MailPersistence", "MailDemo", .product(name: "GRDB", package: "GRDB")]),
        .testTarget(name: "MailIMAPTests", dependencies: ["MailIMAP", "MailDemo", "MailPersistence",
            .product(name: "SwiftMail", package: "SwiftMail")], resources: [.copy("Fixtures")]),
        .testTarget(name: "MailSecurityTests", dependencies: ["MailSecurity", "MailDemo"])
    ]
)
