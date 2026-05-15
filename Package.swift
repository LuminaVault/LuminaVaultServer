// swift-tools-version:6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ObsidianClaudeBrainServer",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18)],
    products: [
        .executable(name: "App", targets: ["App"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-configuration.git", from: "1.0.0", traits: [.defaults, "CommandLineArguments"]),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.7.0"),
        .package(url: "https://github.com/hummingbird-project/swift-openapi-hummingbird.git", from: "2.0.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-auth.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-fluent.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-compression.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.8.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
        .package(url: "https://github.com/LuminaVault/LuminaVaultShared.git", from: "0.7.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", "1.0.0" ..< "3.0.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", from: "1.4.1"),
        .package(url: "https://github.com/swift-server/swift-webauthn.git", from: "1.0.0-alpha.2"),
        .package(url: "https://github.com/swift-server-community/APNSwift.git", from: "6.0.0"),
        .package(url: "https://github.com/slashmo/swift-otel.git", from: "0.10.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .executableTarget(name: "App",
                          dependencies: [
                              .product(name: "Configuration", package: "swift-configuration"),
                              .product(name: "Hummingbird", package: "hummingbird"),
                              .product(name: "HummingbirdAuth", package: "hummingbird-auth"),
                              .product(name: "HummingbirdBasicAuth", package: "hummingbird-auth"),
                              .product(name: "HummingbirdBcrypt", package: "hummingbird-auth"),
                              .product(name: "HummingbirdOTP", package: "hummingbird-auth"),
                              .product(name: "HummingbirdFluent", package: "hummingbird-fluent"),
                              .product(name: "HummingbirdCompression", package: "hummingbird-compression"),
                              .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                              .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
                              .product(name: "JWTKit", package: "jwt-kit"),
                              .product(name: "Logging", package: "swift-log"),
                              .product(name: "Metrics", package: "swift-metrics"),
                              .product(name: "Tracing", package: "swift-distributed-tracing"),
                              .product(name: "WebAuthn", package: "swift-webauthn"),
                              .product(name: "APNS", package: "APNSwift"),
                              .product(name: "OTel", package: "swift-otel"),
                              .product(name: "OTLPGRPC", package: "swift-otel"),
                              .product(name: "LuminaVaultShared", package: "LuminaVaultShared"),
                              .product(name: "Yams", package: "Yams"),
                              .byName(name: "AppAPI"),
                              .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                              .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                          ],
                          path: "Sources/App",
                          resources: [
                              // Use `.copy` (not `.process`) so the per-skill subdirectory
                              // tree is preserved verbatim. `.process` flattens leaves into
                              // a single namespace and collides 5x `SKILL.md`.
                              .copy("Resources/Skills"),
                          ]),
        .target(
            name: "AppAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
            ],
            path: "Sources/AppAPI",
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")],
        ),
        .testTarget(name: "AppTests",
                    dependencies: [
                        .byName(name: "App"),
                        .product(name: "LuminaVaultShared", package: "LuminaVaultShared"),
                        .product(name: "HummingbirdTesting", package: "hummingbird"),
                        .product(name: "HummingbirdAuthTesting", package: "hummingbird-auth"),
                    ],
                    path: "Tests/AppTests"),
    ],
    swiftLanguageVersions: [.v6],
)
