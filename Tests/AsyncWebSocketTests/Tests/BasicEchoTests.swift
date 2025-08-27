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

@MainActor
@Suite(.dependency(\.defaultWebSocketLogger, mainLogger()))
class AsyncWebSocketBasicTests {
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
    "Check connection with invalid WebSocket URL",
    .tags(.connection),
    .timeLimit(.minutes(1)),
  )
  func connectionWithInvalidURL() async throws {
    let openTask = Task {
      let webSocketActor = AsyncWebSocketClient.WebSocketActor()
      try await webSocketActor.open(
        settings: AsyncWebSocketClient.Settings(
          id:  AsyncWebSocketClient.ID(),
          url: "ooo://localhost-\(UUID().uuidString)",
          port: 9999
        )
      )
    }
    
    await Task.yield()
    
    // Checks that an error was thrown from the server.
    let result = await openTask.result
    guard
      case let .failure(error) = result,
      let error = error as? AsyncWebSocketClient.WebSocketActor.WebSocketError
    else {
      #expect(Bool(false))
      return
    }
    
    #expect(error == .invalidWebSocketURLFormat)
  }

  @Test(
    "Check connection Error",
    .tags(.connection),
    .timeLimit(.minutes(1))
  )
  func connectionWithExpectedError() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()

    let id = AsyncWebSocketClient.ID()
    
    await #expect(throws: NIOConnectionError.self)  {
      try await webSocketActor.open(
        settings: AsyncWebSocketClient.Settings(
          id: id,
          url: "ws://localhost-\(UUID().uuidString)",
          port: 9999
        )
      )
    }
    
    // No more active connections.
    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check connection with valid URL",
    .tags(.connection),
    .timeLimit(.minutes(1))
  )
  func connectionWithValidURL() async throws {
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
    
    #expect(await webSocketActor.connections.count == 1)
    
    _ = try #require(
      await webSocketActor.connections.keys.first(where: { $0 == id })
    )
    
    // Closes the connection.
    try await webSocketActor.send(
      id: id,
      frame: .close(code: .normalClosure)
    )
    
   
    // Checks if the connection is closed.
    #expect(try await !webSocketActor.isConnected(id: id))
    
    // No more active connections.
    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check for throwing error when calling send on a closed connection",
    .tags(.connection),
    .timeLimit(.minutes(1))
  )
  
  func callSendOnAClosedConnection() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    
    let id = AsyncWebSocketClient.ID()
    
    await #expect(throws: AsyncWebSocketClient.WebSocketActor.WebSocketError.connectionClosed) {
      try await webSocketActor.send(
        id: id,
        frame: .message(.text("Hello"))
      )
    }
    
    // No more active connections.
    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check calling receive on a closed connection throws an error",
    .tags(.connection),
    .timeLimit(.minutes(1))
  )
  func callReceiveOnAClosedConnection() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    
    let id = AsyncWebSocketClient.ID()
    
    // Checks that an error was thrown from the server.
    await #expect(throws: AsyncWebSocketClient.WebSocketActor.WebSocketError.connectionClosed) {
      _ = try await webSocketActor.receive(id: id)
    }
    
    // No more active connections.
    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check text frame",
    .tags(.frame),
    .timeLimit(.minutes(1))
  )
  func text() async throws {
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
    
    #expect(await webSocketActor.connections.count == 1)

    // Checks if a connection was added to the collection with the corresponding ID.
    _ = try #require(
      await webSocketActor.connections.keys.first(where: { $0 == id })
    )
    
    // Requests to start receiving frames base on id.
    let frameStream = try await webSocketActor.receive(id: id)
    var frameIterator = frameStream.makeAsyncIterator()
    
    try await webSocketActor.send(
      id: id,
      frame: .message(.text("Hello"))
    )
    
    
    #expect(await frameIterator.next() == .message(.text("Hello")))
    try await webSocketActor.send(id: id, frame: .close(code: .normalClosure))

    #expect(await frameIterator.next() == .close(code: .normalClosure))
    #expect(await frameIterator.next() == nil)
    // Checks if the connection is closed.
    #expect(try await !webSocketActor.isConnected(id: id))
    
    // No more active connections.
    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check data frame",
    .tags(.frame),
    .timeLimit(.minutes(1))
  )
  func data() async throws {
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
    
    #expect(await webSocketActor.connections.count == 1)
    
    // Checks if a connection was added to the collection with the corresponding ID.
    _ = try #require(
      await webSocketActor.connections.keys.first(where: { $0 == id })
    )

    // Requests to start receiving frames base on id.
    let frameStream = try await webSocketActor.receive(id: id)
    var frameIterator = frameStream.makeAsyncIterator()
    
    try await webSocketActor.send(
      id: id,
      frame: .message(.binary("Hello".data(using: .utf8)!))
    )
    
    

    #expect(
      await frameIterator.next() == .message( .binary("Hello".data(using: .utf8)!))
    )
    
    try await webSocketActor.send(id: id, frame: .close(code: .normalClosure))
    
    #expect(await frameIterator.next() == .close(code: .normalClosure))
    #expect(await frameIterator.next() == nil)
    
    // Checks if the connection is closed.
    #expect(try await !webSocketActor.isConnected(id: id))
    
    // No more active connections.
    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check ping frame",
    .tags(.frame),
    .timeLimit(.minutes(1))
  )
  func ping() async throws {
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
    
    #expect(await webSocketActor.connections.count == 1)
    
    // Checks if a connection was added to the collection with the corresponding ID.
    _ = try #require(
      await webSocketActor.connections.keys.first(where: { $0 == id })
    )

    // Requests to start receiving frames base on id.
    let frameStream = try await webSocketActor.receive(id: id)
    var frameIterator = frameStream.makeAsyncIterator()
    
    try await webSocketActor.send(id: id, frame: .ping())
    

    #expect(await frameIterator.next() ==  .pong())
    
    try await webSocketActor.send(id: id, frame: .close(code: .normalClosure))
    
    
    #expect(await frameIterator.next() == .close(code: .normalClosure))
    #expect(await frameIterator.next() == nil)
    
    // Checks if the connection is closed.
    #expect(try await !webSocketActor.isConnected(id: id))
    
    // No more active connections.
    #expect(await webSocketActor.connections.count == 0)
  }
  
  // - opens two connections ID1, ID2
  // - sends  ping to ID1
  // - sends  text to ID2
  // - closes ID1
  // - sends  ping to ID2
  // - closes ID2
  @Test(
    "Test multiple connections",
    .tags(.connection),
    .timeLimit(.minutes(1))
  )
  func multipleConnections() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    try #require(self.serverChannel != nil)
    
    let (host, port) = try #require(self.hostAndPort)
    
    let id1 = AsyncWebSocketClient.ID()
    let id2 = AsyncWebSocketClient.ID()

    try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id1,
        url: "ws://\(host)",
        port: port
      )
    )
    
    try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id2,
        url: "ws://\(host)",
        port: port
      )
    )
    
    #expect(await webSocketActor.connections.count == 2)

    // Checks if a connection was added to the collection with the corresponding ID.
    _ = try #require(
      await webSocketActor.connections.keys.first(where: { $0 == id1 })
    )
    _ = try #require(
      await webSocketActor.connections.keys.first(where: { $0 == id2 })
    )
    
    let frameStream1 = try await webSocketActor.receive(id: id1)
    let frameStream2 = try await webSocketActor.receive(id: id2)
    
    var frameIterator1 = frameStream1.makeAsyncIterator()
    var frameIterator2 = frameStream2.makeAsyncIterator()
    
    try await webSocketActor.send(id: id1, frame: .ping())
    
    // Sends text frame to the server for id2.
    try await webSocketActor.send(id: id2, frame: .message(.text("Hello")))
    
    
    #expect(await frameIterator1.next() == .pong())
    #expect(await frameIterator2.next() == .message(.text("Hello")))
    
    // Closes connection for id1.
    try await webSocketActor.send( id: id1, frame: .close(code: .goingAway))
    
    // Sends ping frame to the server for id2.
    try await webSocketActor.send(id: id2, frame: .ping("Task id2 ping".data(using: .utf8)!))
    
    #expect(await frameIterator1.next() == .close(code: .goingAway))
    #expect(await frameIterator1.next() == nil)
    #expect(await webSocketActor.connections.count == 1)

    // Checks that connection is closed for id1.
    #expect(try await !webSocketActor.isConnected(id: id1))
    
    // Checks pong response for id2.
    #expect(
      await frameIterator2.next() == .pong("Task id2 ping".data(using: .utf8)!)
    )
    
    // Closes connection for id2.
    try await webSocketActor.send(id: id2, frame: .close(code: .normalClosure))
    
    #expect(await frameIterator2.next() == .close(code: .normalClosure))
    #expect(await frameIterator2.next() == nil)
    
    // Checks that connection is closed for id2.
    #expect(try await !webSocketActor.isConnected(id: id2))
    
    // No more active connections.
    #expect(await webSocketActor.connections.count == 0)
  }
}

extension HTTPHandler: @unchecked Sendable { }

extension Tag {
  @Tag static var connection: Self
  @Tag static var frame: Self
}

