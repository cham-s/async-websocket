import AsyncWebSocketClient
import Foundation
import NIOCore
import NIOWebSocket
import NIOHTTP1
import NIOPosix
import Testing
@testable import AsyncWebSocketClientLive

@MainActor
class AsyncWebSocketClientTests {
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
    "Check connection with valid URL",
    .tags(.connection)
  )
  func connectionWithValidURL() async throws {
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
    
    // Checks connection status evolution.
    var statusIterator = statuses.makeAsyncIterator()
    var status = await statusIterator.next()
    
    // Checks for status evolution.
    #expect(status == .connecting)
    
    status = await statusIterator.next()
    
    #expect(status == .connected)
    #expect(await webSocketActor.connections.count == 1)
    
    let firstId = try #require(await webSocketActor.connections.keys.first)
    
    #expect(firstId == id)
    
    // Closes the connection.
    try await webSocketActor.send(
      id: id,
      frame: .close(code: .normalClosure)
    )
    
    #expect(await statusIterator.next() == .didClose(.normalClosure))
    #expect(await statusIterator.next() == nil)
    
    // Checks if the connection is closed.
    let isClosed = try await connectionIsClosed(webSocketActor, id: id)
    #expect(isClosed)
  }
  
  
  @Test(
    "Check for throwing error when calling send on a closed connection",
    .tags(.connection)
  )
  
  func callSendOnAClosedConnection() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    
    let id = AsyncWebSocketClient.ID()
    
    let isClosed = try await connectionIsClosed(webSocketActor, id: id)
    #expect(isClosed)
  }
  
  @Test(
    "Check calling receive on a closed connection throws an error",
    .tags(.connection)
  )
  func callReceiveOnAClosedConnection() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    
    let id = AsyncWebSocketClient.ID()
    
    // Attemps to subrscribe for incoming frames.
    let sendTask = Task { _ = try await webSocketActor.receive(id: id) }
    
    await Task.yield()
    
    // Checks that an error was thrown from the server.
    let result = await sendTask.result
    guard
      case let .failure(error) = result,
      let error = error as? AsyncWebSocketClient.WebSocketActor.WebSocketError
    else {
      throw WebSocketExpectationFailure()
    }
    #expect(error == .connectionClosed)
  }
  
  @Test(
    "Check text frame",
    .tags(.frame)
  )
  func text() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    try #require(self.serverChannel != nil)
    
    let (host, port) = try #require(self.hostAndPort)
    
    let id = AsyncWebSocketClient.ID()
    
    // Subscribes for connection statuses.
    let statuses = try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id,
        url: "ws://\(host)",
        port: port
      )
    )
    
    // Checks for status evolution.
    var statusIterator = statuses.makeAsyncIterator()
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    
    // Checks if a connection was added to the collection with the corresponding ID.
    _ = try #require(
      await webSocketActor.connections.keys.first(where: { $0 == id })
    )
    
    // Requests to start receiving frames base on id.
    let frameStream = try await webSocketActor.receive(id: id)
    var frameIterator = frameStream.makeAsyncIterator()
    
    // Sends frame to the server.
    let frameTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .message(.text("Hello"))
      )
    }
    
    await Task.yield()
    _ = try await frameTask.value

    #expect(await frameIterator.next() == .message(.text("Hello")))
    
    // Closes the connection.
    let closeTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .close(code: .normalClosure)
      )
    }
    
    await Task.yield()
    _ = try await closeTask.value
    
    #expect(await statusIterator.next() == .didClose(.normalClosure))
    #expect(await frameIterator.next() == .close(code: .normalClosure))
    #expect(await frameIterator.next() == nil)
    #expect(await statusIterator.next() == nil)
    
    // Checks if the connection is closed.
    let isClosed = try await connectionIsClosed(webSocketActor, id: id)
    #expect(isClosed)
  }
  
  @Test(
    "Check data frame",
    .tags(.frame)
  )
  func data() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    try #require(self.serverChannel != nil)
    
    let (host, port) = try #require(self.hostAndPort)
    
    let id = AsyncWebSocketClient.ID()
    
    // Subscribes for connection statuses.
    let statuses = try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id,
        url: "ws://\(host)",
        port: port
      )
    )
    
    // Checks for status evolution.
    var statusIterator = statuses.makeAsyncIterator()
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    
    #expect(await webSocketActor.connections.count == 1)
    
    // Checks if a connection was added to the collection with the corresponding ID.
    _ = try #require(
      await webSocketActor.connections.keys.first(where: { $0 == id })
    )

    // Requests to start receiving frames base on id.
    let frameStream = try await webSocketActor.receive(id: id)
    var frameIterator = frameStream.makeAsyncIterator()
    
    // Sends frame to the server.
    let frameTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .message(.binary("Hello".data(using: .utf8)!))
      )
    }
    
    
    await Task.yield()
    _ = try await frameTask.value

    #expect(
      await frameIterator.next() ==  .message(
        .binary("Hello".data(using: .utf8)!)
      )
    )
    
    // Closes the connection.
    let closeTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .close(code: .normalClosure)
      )
    }
    
    await Task.yield()
    _ = try await closeTask.value
    
    #expect(await statusIterator.next() == .didClose(.normalClosure))
    #expect(await frameIterator.next() == .close(code: .normalClosure))
    #expect(await frameIterator.next() == nil)
    #expect(await statusIterator.next() == nil)
    
    // Checks if the connection is closed.
    let isClosed = try await connectionIsClosed(webSocketActor, id: id)
    #expect(isClosed)
  }
  
  @Test(
    "Check ping frame",
    .tags(.frame)
  )
  func ping() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    try #require(self.serverChannel != nil)
    
    let (host, port) = try #require(self.hostAndPort)
    
    let id = AsyncWebSocketClient.ID()
    
    // Subscribes for connection statuses.
    let statuses = try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id,
        url: "ws://\(host)",
        port: port
      )
    )
    
    var statusIterator = statuses.makeAsyncIterator()
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    
    #expect(await webSocketActor.connections.count == 1)
    
    // Checks if a connection was added to the collection with the corresponding ID.
    _ = try #require(
      await webSocketActor.connections.keys.first(where: { $0 == id })
    )

    // Requests to start receiving frames base on id.
    let frameStream = try await webSocketActor.receive(id: id)
    var frameIterator = frameStream.makeAsyncIterator()
    
    // Sends frame to the server.
    let frameTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .ping()
      )
    }
    
    await Task.yield()
    _ = try await frameTask.value

    #expect(await frameIterator.next() ==  .pong())
    
    let closeTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .close(code: .normalClosure)
      )
    }
    
    await Task.yield()
    _ = try await closeTask.value
    
    #expect(await statusIterator.next() == .didClose(.normalClosure))
    #expect(await frameIterator.next() == .close(code: .normalClosure))
    #expect(await frameIterator.next() == nil)
    #expect(await statusIterator.next() == nil)
    
    // Checks if the connection is closed.
    let isClosed = try await connectionIsClosed(webSocketActor, id: id)
    #expect(isClosed)
  }
  
  // - opens two connections ID1, ID2
  // - sends  ping to ID1
  // - sends  text to ID2
  // - closes ID1
  // - sends  ping to ID2
  // - closes ID2
  @Test( "Test multiple connections ")
  func multipleConnections() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
    try #require(self.serverChannel != nil)
    
    let (host, port) = try #require(self.hostAndPort)
    
    let id1 = AsyncWebSocketClient.ID()
    let id2 = AsyncWebSocketClient.ID()

    // Subscribes for connection statuses for id1.
    let statuses1 = try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id1,
        url: "ws://\(host)",
        port: port
      )
    )
    
    // Subscribes for connection statuses for id2.
    let statuses2 = try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id2,
        url: "ws://\(host)",
        port: port
      )
    )
    
    // Checks for status evolution for id1.
    var statusIterator1 = statuses1.makeAsyncIterator()
    #expect(await statusIterator1.next() == .connecting)
    #expect(await statusIterator1.next() == .connected)

    // Checks for status evolution for id2.
    var statusIterator2 = statuses2.makeAsyncIterator()
    #expect(await statusIterator2.next() == .connecting)
    #expect(await statusIterator2.next() == .connected)
    
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
    
    // Sends ping frame to the server for id1.
    let frameTask1 = Task {
      try await webSocketActor.send(
        id: id1,
        frame: .ping()
      )
    }
    
    // Sends text frame to the server for id2.
    let frameTask2 = Task {
      try await webSocketActor.send(
        id: id2,
        frame: .message(.text("Hello"))
      )
    }
    
    await Task.yield()
    _ = try await frameTask1.value
    _ = try await frameTask2.value
    
    #expect(await frameIterator1.next() == .pong())
    #expect(await frameIterator2.next() == .message(.text("Hello")))
    
    // Closes connection for id1.
    let closeId1Task = Task {
      try await webSocketActor.send(
        id: id1,
        frame: .close(code: .goingAway)
      )
    }
    
    // Sends ping frame to the server for id2.
    let pingId2Task = Task {
      try await webSocketActor.send(
        id: id2,
        frame: .ping("Task id2 ping".data(using: .utf8)!)
      )
    }
    
    await Task.yield()
    _ = try await closeId1Task.value
    _ = try await pingId2Task.value
    
    #expect(await frameIterator1.next() == .close(code: .goingAway))
    #expect(await statusIterator1.next() == .didClose(.goingAway))
    #expect(await frameIterator1.next() == nil)
    #expect(await statusIterator1.next() == nil)
    
    // Checks that connection is closed for id1.
    let isClosedId1 = try await connectionIsClosed(webSocketActor, id: id1)
    #expect(isClosedId1)
    
    // Checks pong response for id2.
    #expect(
      await frameIterator2.next() == .pong("Task id2 ping".data(using: .utf8)!)
    )
    
    // Closes connection for id2.
    let closeId2Task = Task {
      try await webSocketActor.send(
        id: id2,
        frame: .close(code: .normalClosure)
      )
    }
    
    await Task.yield()
    _ = try await closeId2Task.value
    
    #expect(await frameIterator2.next() == .close(code: .normalClosure))
    #expect(await statusIterator2.next() == .didClose(.normalClosure))
    #expect(await frameIterator2.next() == nil)
    #expect(await statusIterator2.next() == nil)
    
    // Checks that connection is closed for id2.
    let isClosedId2 = try await connectionIsClosed(webSocketActor, id: id1)
    #expect(isClosedId2)
  }
}

extension HTTPHandler: @unchecked Sendable { }

extension Tag {
  @Tag static var connection: Self
  @Tag static var frame: Self
}

fileprivate struct WebSocketExpectationFailure: Error { }

@MainActor
func connectionIsClosed(
  _ webSocketActor: AsyncWebSocketClient.WebSocketActor,
  id: AsyncWebSocketClient.ID
) async throws -> Bool {
  let sendTask = Task {
    try await webSocketActor.send(
      id: id,
      frame: .message(.text("Hello"))
    )
  }
  
  await Task.yield()
  
  let result = await sendTask.result
  guard
    case let .failure(error) = result,
    let error = error as? AsyncWebSocketClient.WebSocketActor.WebSocketError
  else {
    throw WebSocketExpectationFailure()
  }
  return error == .connectionClosed
}
