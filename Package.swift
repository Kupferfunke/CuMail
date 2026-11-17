// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MikeMailHub",
    defaultLocalization: "de",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "MikeMailHub", targets: ["MikeMailHub"]),
               .executable(name: "MikeMailBridge", targets: ["MikeMailBridge"])],
    dependencies: [.package(path: "Packages/MikeMailCore")],
    targets: [
        .executableTarget(
            name: "MikeMailHub",
            dependencies: [
                .product(name: "MailDomain", package: "MikeMailCore"),
                .product(name: "MailApplication", package: "MikeMailCore"),
                .product(name: "MailDemo", package: "MikeMailCore"),
                .product(name: "MailPersistence", package: "MikeMailCore"),
                .product(name: "MailSecurity", package: "MikeMailCore"),
                .product(name: "MailIMAP", package: "MikeMailCore"),
                .product(name: "MailGoogle", package: "MikeMailCore"),
                .product(name: "MailRendering", package: "MikeMailCore"),
                .product(name: "MailMCP", package: "MikeMailCore")
            ],
            path: "App",
            resources: [.copy("Resources/Brand"), .copy("Resources/Fonts"), .copy("Resources/Licenses"), .copy("Resources/AppIcon.icns"), .process("Resources/Localizations")],
            // The local .app embeds SQLCipher here, matching Xcode's app runpath.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(name: "MikeMailBridge", path: "Services/MailBridge"),
        .testTarget(name: "MikeMailHubTests", dependencies: ["MikeMailHub"], path: "Tests/AppTests")
    ]
)
