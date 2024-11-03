import AsyncWebSocketClient
import Dependencies
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
//    #expect(await webSocketActor.connections.count == 0)
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
    
    var statusIterator = statuses.makeAsyncIterator()
    var status = await statusIterator.next()
    
    #expect(status == .connecting)
    
    status = await statusIterator.next()
    
    #expect(status == .connected)
    #expect(await webSocketActor.connections.count == 1)
    
    let firstId = try #require(await webSocketActor.connections.keys.first)
    
    #expect(firstId == id)
    
    try await webSocketActor.send(
      id: id,
      frame: .close(code: .normalClosure)
    )
    
    status = await statusIterator.next()
    
    #expect(status == .didClose(.normalClosure))
//    try await Task.sleep(for: .milliseconds(1))
//    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check for throwing error when calling send on a closed connection",
    .tags(.connection)
  )
  func callSendOnAClosedConnection() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
//    #expect(await webSocketActor.connections.count == 0)
    
    let id = AsyncWebSocketClient.ID()
    
    do {
      try await webSocketActor.send(
        id: id,
        frame: .message(.text("Hello"))
      )
      
    } catch {
      let connectionError = error as? AsyncWebSocketClient.WebSocketActor.WebSocketError
      #expect(connectionError == .connectionClosed)
    }
  }
  
  @Test(
    "Check calling receive on a closed connection throws an error",
    .tags(.connection)
  )
  func callReceiveOnAClosedConnection() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
//    #expect(await webSocketActor.connections.count == 0)
    
    let id = AsyncWebSocketClient.ID()
    
    do {
      _ = try await webSocketActor.receive(id: id)
    } catch {
      let connectionError = error as? AsyncWebSocketClient.WebSocketActor.WebSocketError
      #expect(connectionError == .connectionClosed)
    }
  }
  
//  @Test(
//    "Check sending a frame",
//    .tags(.frame),
//    .serialized,
//    arguments: [
//      AsyncWebSocketClient.Frame.ping(),
//      .message(.binary("Hello".data(using: .utf8)!)),
//    ]
//  )
//  func frame(frame: AsyncWebSocketClient.Frame) async throws {
//    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
//    #expect(await webSocketActor.connections.count == 0)
//    try #require(self.serverChannel != nil)
//    
//    let (host, port) = try #require(self.hostAndPort)
//    
//    let id = AsyncWebSocketClient.ID()
//    
//    let statuses = try await webSocketActor.open(
//      settings: AsyncWebSocketClient.Settings(
//        id: id,
//        url: "ws://\(host)",
//        port: port
//      )
//    )
//    
//    var statusIterator = statuses.makeAsyncIterator()
//    #expect(await statusIterator.next() == .connecting)
//    #expect(await statusIterator.next() == .connected)
//    
//    #expect(await webSocketActor.connections.count == 1)
//    
//    let connectionId = try #require(await webSocketActor.connections.keys.first)
//    #expect(connectionId == id)
//    
//    let frameStream = try await webSocketActor.receive(id: id)
//    var frameIterator = frameStream.makeAsyncIterator()
//    
//    let frameTask = Task {
//      if frame.is(\.message.text) {
//        try await webSocketActor.send(
//          id: id,
//          frame: .message(.text("Hello"))
//        )
//      } else if frame.is(\.message.binary) {
//        try await webSocketActor.send(
//          id: id,
//          frame: .message(.binary("Hello".data(using: .utf8)!))
//        )
//      } else if frame.is(\.ping) {
//        try await webSocketActor.send(
//          id: id,
//          frame: .ping()
//        )
//      }
//    }
//    
//    await Task.yield()
//    _ = try await frameTask.value
//
//    let receivedFrame = await frameIterator.next()
//    
//    if frame.is(\.message.text) {
//      #expect(receivedFrame == .message(.text("Hello")))
//    } else if frame.is(\.message.binary) {
//      #expect(receivedFrame == .message(.binary("Hello".data(using: .utf8)!)))
//    } else if frame.is(\.ping) {
//      #expect(receivedFrame == .pong())
//    }
//    
//    let closeTask = Task {
//      try await webSocketActor.send(
//        id: id,
//        frame: .close(code: .normalClosure)
//      )
//    }
//    
//    await Task.yield()
//    _ = try await closeTask.value
//    
//    #expect(await statusIterator.next() == .didClose(.normalClosure))
//    
//    try await Task.sleep(for: .nanoseconds(500))
//    #expect(await webSocketActor.connections.count == 0)
//
//  }
  
  @Test(
    "Check text frame",
    .tags(.frame)
  )
  func text() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
//    #expect(await webSocketActor.connections.count == 0)
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
    
    var statusIterator = statuses.makeAsyncIterator()
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    
    #expect(await webSocketActor.connections.count == 1)
    
    let connectionId = try #require(await webSocketActor.connections.keys.first)
    #expect(connectionId == id)
    
    let frameStream = try await webSocketActor.receive(id: id)
    var frameIterator = frameStream.makeAsyncIterator()
    
    let frameTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .message(.text("Hello"))
      )
    }
    
    await Task.yield()
    _ = try await frameTask.value

    let receivedFrame = await frameIterator.next()
    
    #expect(receivedFrame == .message(.text("Hello")))
    
    let closeTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .close(code: .normalClosure)
      )
    }
    
    await Task.yield()
    _ = try await closeTask.value
    
    #expect(await statusIterator.next() == .didClose(.normalClosure))
    
//    try await Task.sleep(for: .nanoseconds(500))
//    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check data frame",
    .tags(.frame)
  )
  
  func data() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
//    #expect(await webSocketActor.connections.count == 0)
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
    
    var statusIterator = statuses.makeAsyncIterator()
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    
    #expect(await webSocketActor.connections.count == 1)
    
    let connectionId = try #require(await webSocketActor.connections.keys.first)
    #expect(connectionId == id)
    
    let frameStream = try await webSocketActor.receive(id: id)
    var frameIterator = frameStream.makeAsyncIterator()
    
    let frameTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .message(.binary("Hello".data(using: .utf8)!))
      )
    }
    
    await Task.yield()
    _ = try await frameTask.value

    let receivedFrame = await frameIterator.next()
    
    #expect(receivedFrame ==  .message(.binary("Hello".data(using: .utf8)!)))
    
    let closeTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .close(code: .normalClosure)
      )
    }
    
    await Task.yield()
    _ = try await closeTask.value
    
    #expect(await statusIterator.next() == .didClose(.normalClosure))
    
//    try await Task.sleep(for: .nanoseconds(500))
//    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check data frame",
    .tags(.frame)
  )
  func ping() async throws {
    let webSocketActor = AsyncWebSocketClient.WebSocketActor()
//    #expect(await webSocketActor.connections.count == 0)
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
    
    var statusIterator = statuses.makeAsyncIterator()
    #expect(await statusIterator.next() == .connecting)
    #expect(await statusIterator.next() == .connected)
    
    #expect(await webSocketActor.connections.count == 1)
    
    let connectionId = try #require(await webSocketActor.connections.keys.first)
    #expect(connectionId == id)
    
    let frameStream = try await webSocketActor.receive(id: id)
    var frameIterator = frameStream.makeAsyncIterator()
    
    let frameTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .ping()
      )
    }
    
    await Task.yield()
    _ = try await frameTask.value

    let receivedFrame = await frameIterator.next()
    
    #expect(receivedFrame ==  .pong())
    
    let closeTask = Task {
      try await webSocketActor.send(
        id: id,
        frame: .close(code: .normalClosure)
      )
    }
    
    await Task.yield()
    _ = try await closeTask.value
    
    #expect(await statusIterator.next() == .didClose(.normalClosure))
    
//    try await Task.sleep(for: .nanoseconds(500))
//    #expect(await webSocketActor.connections.count == 0)

  }
}

extension HTTPHandler: @unchecked Sendable { }

extension Tag {
  @Tag static var connection: Self
  @Tag static var frame: Self
}
