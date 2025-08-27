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
class CodableOperatorWithUsersHandlerTests {
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
        channel.pipeline.addHandler(UsersHandler())
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
    "Check receiving a response message from request getUsers",
    .tags(.codable),
    .timeLimit(.minutes(1))
  )
  func receiveAUser() async throws {
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
    
    /// Task handling the stream of frame logic.
    let messages = try await webSocketActor
      .receive(id: id)
      .success(of: Message.self)
    
    let request = Message.request(.single(.getUsers(count: .two)))
    let data = try JSONEncoder().encode(request)
    try await webSocketActor.send(id: id, frame: .message(.binary(data)))
    var messageIterator = messages.makeAsyncIterator()
    
    #expect(
      await messageIterator.next()
      == Message.response(
        .success(
          .getUsers(
            .init(
              users: [
                User(id: 1, name: "A"),
                User(id: 2, name: "B"),
              ]
            )
          )
        )
      )
    )
    
    try await webSocketActor.send(id: id, frame: .close(code: .normalClosure))
    
    #expect(try await !webSocketActor.isConnected(id: id))
    
    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check starting and stopping the stream",
    .tags(.codable),
    .timeLimit(.minutes(1))
  )
  func startThenStopStreamResponse() async throws {
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
    
    let responses = try await webSocketActor
      .receive(id: id)
      .success(of: Message.self)
      .case(\.response)
    
    var responsesIterator = responses.makeAsyncIterator()
    
    
    let startStream = Message.request(.single(.startStream))
    let startData = try JSONEncoder().encode(startStream)
    try await webSocketActor.send(id: id, frame: .message(.binary(startData)))
    #expect(await responsesIterator.next() == .success(.startStream))
    
    /// Stops the stream of User.
    let stopStream = Message.request(.single(.stopStream))
    let stopData = try JSONEncoder().encode(stopStream)
    try await webSocketActor.send(id: id, frame: .message(.binary(stopData)))
    #expect(await responsesIterator.next() == .success(.stopStream))
    
    try await webSocketActor.send(id: id, frame: .close(code: .normalClosure))
    
    #expect(try await !webSocketActor.isConnected(id: id))
    #expect(await webSocketActor.connections.count == 0)
  }
  
  
  @Test(
    "Check response failure on already started stream",
    .tags(.codable),
    .timeLimit(.minutes(1))
  )
  func failureOnStartStreaemAlreadyStarted() async throws {
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
    
    let responses = try await webSocketActor
      .receive(id: id)
      .success(of: Message.self)
      .case(\.response)
    
    var responsesIterator = responses.makeAsyncIterator()
    /// Starts the stream of User.
    let startRequest = Message.request(.single(.startStream))
    let startData = try JSONEncoder().encode(startRequest)
    try await webSocketActor.send(id: id, frame: .message(.binary(startData)))
    #expect(await responsesIterator.next() == .success(.startStream))
    
    /// Starts the stream of User again.
    let startAgainRequest = Message.request(.single(.startStream))
    let startAgainData = try JSONEncoder().encode(startAgainRequest)
    try await webSocketActor.send(id: id, frame: .message(.binary(startAgainData)))
    
    #expect(
      await responsesIterator.next() == .failure(
        RequestError(
          code: .streamAlreadyStarted,
          reason: nil
        )
      )
    )
    
    try await webSocketActor.send(id: id, frame: .close(code: .normalClosure))
    
    #expect(try await !webSocketActor.isConnected(id: id))
    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check failure on trying to stop a stream that hasn't started yet",
    .tags(.codable),
    .timeLimit(.minutes(1))
  )
  func failureOnStopNotStartedStream() async throws {
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
    
    /// Task handling the stream of frame logic.
    let responsesFailures = try await webSocketActor
      .receive(id: id)
      .success(of: Message.self)
      .case(\.response.failure)
    
    var failureIterator = responsesFailures.makeAsyncIterator()
    
    /// Stops the stream of User.
    let stopStreamRequest = Message.request(.single(.stopStream))
    let data = try JSONEncoder().encode(stopStreamRequest)
    try await webSocketActor.send(id: id, frame: .message(.binary(data)))
    #expect( await failureIterator.next() == RequestError(
      code: .streamNotStarted,
      reason: nil
    )
    )
    
    
    try await webSocketActor.send(id: id, frame: .close(code: .normalClosure))
    
    #expect(try await !webSocketActor.isConnected(id: id))
    #expect(await webSocketActor.connections.count == 0)
  }
  
  @Test(
    "Check batch request with field operator",
    .tags(.codable),
    .timeLimit(.minutes(1))
  )
  func batchRequest() async throws {
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
    
    let users = try await webSocketActor
      .receive(id: id)
      .success(of: Message.self)
      .case(\.response.success.getUsers)
      .field(\.users)
    
    var usersIterator = users.makeAsyncIterator()

    let request = Message.request(
      .batch([
        .getUsers(count: .one),
        .getUsers(count: .two),
        .getUsers(count: .three),
      ])
    )
    let data = try JSONEncoder().encode(request)
    try await webSocketActor.send(id: id, frame: .message(.binary(data)))
    
    #expect(await usersIterator.next() == [.a])
    #expect(await usersIterator.next() == [.a, .b])
    #expect(await usersIterator.next() == [.a, .b, .c])
    
    // Close the connection
    try await webSocketActor.send(id: id, frame: .close(code: .normalClosure))
    
    #expect(try await !webSocketActor.isConnected(id: id))
    
    // Checks if there is no more active connection inside the actor.
    #expect(await webSocketActor.connections.count == 0)
  }
}

extension Tag {
  @Tag static var codable: Self
}
