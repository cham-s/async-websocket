// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "async-websocket",
  platforms: [
    .iOS(.v13),
    .macOS(.v11),
    .tvOS(.v13),
    .watchOS(.v6),
    .visionOS(.v1)
  ],
  products: [
    // MARK: - Umbrella Modules
    .library(name: "AsyncWebSocket", targets: ["AsyncWebSocket"]),
    
    // MARK: - Interfaces
    .library(name: "AsyncWebSocketClient", targets: ["AsyncWebSocketClient"]),
    
    // MARK: - Live Implementations
    .library(name: "AsyncWebSocketClientLive", targets: ["AsyncWebSocketClientLive"]),
    
    // MARK: - Operators
    .library(name: "AsyncWebSocketOperators", targets: ["AsyncWebSocketOperators"]),
  ],
  
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.76.1"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.6.1"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.4.1"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump.git", from: "1.3.3"),
    .package(url: "https://github.com/pointfreeco/swift-case-paths.git", from: "1.5.6"),
    .package(url: "https://github.com/pointfreeco/swift-tagged.git", from: "0.10.0"),
    .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
    .package(url: "https://github.com/cham-s/general-types", from: "0.1.1-beta"),
  ],
  
  targets: [
    // MARK: - Umbrella Modules
    .target(
       name: "AsyncWebSocket",
       dependencies: [
         "AsyncWebSocketClient",
         "AsyncWebSocketClientLive",
         "AsyncWebSocketOperators",
         .product(name: "NIOCore", package: "swift-nio"),
         .product(name: "NIOPosix", package: "swift-nio"),
         .product(name: "Dependencies", package: "swift-dependencies"),
         .product(name: "WebSocketKit", package: "websocket-kit"),
       ]
     ),
    
    // MARK: - Interface
    .target(
      name: "AsyncWebSocketClient",
      dependencies: [
        .product(name: "NIOWebSocket", package: "swift-nio"),
        .product(name: "WebSocketKit", package: "websocket-kit"),
        .product(name: "CasePaths", package: "swift-case-paths"),
        .product(name: "Tagged", package: "swift-tagged"),
      ]
    ),
    
    // MARK: - Live Implementation
    .target(
      name: "AsyncWebSocketClientLive",
      dependencies: [
        "AsyncWebSocketClient",
        .product(name: "Dependencies", package: "swift-dependencies"),
        .product(name: "AsyncStreamTypes", package: "general-types"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "WebSocketKit", package: "websocket-kit"),
      ]
    ),
    
    // MARK: - Operators
    .target(
      name: "AsyncWebSocketOperators",
      dependencies: [
        "AsyncWebSocketClient",
        .product(name: "CasePaths", package: "swift-case-paths"),
        .product(name: "Logging", package: "swift-log"),
        .product(name: "CustomDump", package: "swift-custom-dump"),
      ]
    ),

    // MARK: - Tests
    .testTarget(
       name: "AsyncWebSocketTests",
       dependencies: [
         "AsyncWebSocketClient",
         "AsyncWebSocketClientLive",
         "AsyncWebSocketOperators",
         .product(name: "Dependencies", package: "swift-dependencies"),
         .product(name: "NIOCore", package: "swift-nio"),
         .product(name: "NIOEmbedded", package: "swift-nio"),
         .product(name: "NIOHTTP1", package: "swift-nio"),
         .product(name: "NIOPosix", package: "swift-nio"),
         .product(name: "NIOWebSocket", package: "swift-nio"),
       ]
     ),
  ]
)
