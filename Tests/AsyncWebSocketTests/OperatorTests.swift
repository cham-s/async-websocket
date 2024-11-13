import AsyncWebSocketClient
import Dependencies
import Foundation
import NIOCore
import NIOWebSocket
import NIOHTTP1
import NIOPosix
import Testing
@testable import AsyncWebSocketClientLive
@testable import AsyncWebSocketOperators

@MainActor
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
    .tags(.operator)
  )
  func onConnected() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    try #require(self.serverChannel != nil)
    
    let (host, port) = try #require(self.hostAndPort)
    let id = AsyncWebSocketClient.ID()
    
    let statuses = try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id,
        url: "ws://\(host)",
        port: port
      )
    )
    
    
    // Checks if a connected event has been emitted
    var isConnected = false
    let didFail = LockIsolated<Bool>(false)
    let closeCode = LockIsolated<WebSocketErrorCode?>(nil)
    for await _ in statuses
      .on(
        \.connected,
         onDidClose: { code in
           closeCode.withValue { $0 =  code}
         },
         onDidFail: { _ in
           didFail.withValue { $0 = true }
           fatalError()
         }) {
      
      isConnected = true
      
      // Checks if the connection is active.
      #expect(await webSocketActor.connections.count == 1)
      
      // Checks if the connection is related to the current id.
      _ = try #require(
        await webSocketActor.connections.keys.first(where: { $0 == id })
      )

      // Close the connection
      try await webSocketActor.send(
        id: id,
        frame: .close(code: .normalClosure)
      )
    }
      
    #expect(isConnected)
    #expect(didFail.value == false)
    #expect(closeCode.value == .normalClosure)

    // Checks if the connection is closed.
    let isClosed = try await connectionIsClosed(webSocketActor, id: id)
    #expect(isClosed)
    
    // Checks if there is no more active connection inside the actor.
    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Checks failed the connected case",
    .tags(.operator)
  )
  func onConnectedFailure() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    let id = AsyncWebSocketClient.ID()
    
    let statuses = try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id,
        url: "ws://-localhost\(UUID().uuidString)",
        port: 9999
      )
    )
    let count = await webSocketActor.connections.count
    // Checks if the connection is active.
    #expect(await webSocketActor.connections.count == 0)
    
    // Checks if a connected event has been emitted
    var isConnected = false
    let didFail = LockIsolated<Bool>(false)
    for await _ in statuses.on(
      \.connected,
       onDidClose: { code in
         fatalError()
       },
       onDidFail: { _ in
         didFail.withValue { $0 = true }
       }
    ) {
      isConnected = true
      
      // Close the connection
      try await webSocketActor.send(
        id: id,
        frame: .close(code: .normalClosure)
      )
    }
    
    #expect(didFail.value == true)
    #expect(isConnected == false)
  }
}

extension Tag {
  @Tag static var `operator`: Self
}
  
