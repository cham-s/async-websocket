import AsyncWebSocketClient
import Dependencies
import DependenciesTestSupport
import Foundation
import NIOCore
import NIOWebSocket
import NIOHTTP1
import NIOPosix
import Testing
@testable import AsyncWebSocketClientLive
@testable import AsyncWebSocketOperators

@MainActor
@Suite(.dependency(\.defaultWebSocketLogger, mainLogger()))
class AsyncWebSocketOperatorsTests {
  private var group: EventLoopGroup!
  
  private var serverChannel: Channel!
  private var serverAddress: SocketAddress {
    self.serverChannel.localAddress!
  }
  
  private var hostAndPort: (String, Int)? {
    guard
      let host = self.serverChannel.localAddress?.ipAddress,
      let port = self.serverChannel.localAddress?.port
    else { return nil }
    
    return (host, port)
  }
  
  init() throws {
    try setup()
  }
  
  deinit {
    do {
      if self.serverChannel != nil {
        try self.serverChannel?.close().wait()
        try self.group.syncShutdownGracefully()
      }
    } catch {
      print("Failed to close server channel: \(error)")
    }
  }
  
  func setup() throws {
    self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    
    let upgrader = NIOWebSocketServerUpgrader(
      shouldUpgrade: { channel, _ in
        channel.eventLoop.makeSucceededFuture(HTTPHeaders())
      },
      upgradePipelineHandler: { channel, _ in
        channel.pipeline.addHandler(WebSocketEchoHandler())
      }
    )
    
    self.serverChannel = try ServerBootstrap(group: self.group)
      .childChannelInitializer { channel in
        let httpHandler = HTTPHandler()
        let config: NIOHTTPServerUpgradeConfiguration = (
          upgraders: [upgrader],
          completionHandler: { _ in
            channel.pipeline.removeHandler(httpHandler, promise: nil)
          }
        )
        
        return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config)
          .flatMap {
            channel.pipeline.addHandler(httpHandler)
          }
      }
      .bind(host: "127.0.0.1", port: 0)
      .wait()
  }
  
  @Test(
    "Check successful connected case",
    .tags(.operator),
    .timeLimit(.minutes(1))
  )
  func onConnected() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    try #require(self.serverChannel != nil)
    
    let (host, port) = try #require(self.hostAndPort)
    let id = AsyncWebSocketClient.ID()
    
    try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id,
        url: "ws://\(host)",
        port: port
      )
    )
    
    #expect(try await webSocketActor.isConnected(id: id))
    
      
    // Checks if the connection is active.
    #expect(await webSocketActor.connections.count == 1)
      
    // Checks if the connection is related to the current id.
    _ = try #require(
      await webSocketActor.connections.keys.first(where: { $0 == id })
    )

    try await webSocketActor.send(id: id, frame: .close(code: .normalClosure))
      
    #expect(try await !webSocketActor.isConnected(id: id))
    
    // Checks if there is no more active connection inside the actor.
    #expect(await webSocketActor.connections.count == 0)
  }

  @Test(
    "Check text case",
    .tags(.operator),
    .timeLimit(.minutes(1))
  )
  func onText() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    try #require(self.serverChannel != nil)
    
    let (host, port) = try #require(self.hostAndPort)
    let id = AsyncWebSocketClient.ID()
    
    try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id,
        url: "ws://\(host)",
        port: port
      )
    )
    
    #expect(try await webSocketActor.isConnected(id: id))
    
    // Checks if the connection is active.
    #expect(await webSocketActor.connections.count == 1)
    
    // Checks if the connection is related to the current id.
    _ = try #require(
      await webSocketActor.connections.keys.first(where: { $0 == id })
    )
    
    let frames = try await webSocketActor
      .receive(id: id)
      .on(\.message.text)
    
    var frameIterator = frames.makeAsyncIterator()
    try await webSocketActor.send(id: id, frame: .message(.text("Hello")))
    try await webSocketActor.send(id: id, frame: .message(.text(", world!")))
    
    var message = try #require(await frameIterator.next())
    message += try #require(await frameIterator.next())
    
    #expect(message == "Hello, world!")

    // Close the connection
    try await webSocketActor.send(id: id, frame: .close(code: .normalClosure))
    
    #expect(try await !webSocketActor.isConnected(id: id))
    
    // Checks if there is no more active connection inside the actor.
    #expect(await webSocketActor.connections.count == 0)
  }
}

extension Tag {
  @Tag static var `operator`: Self
}
  
