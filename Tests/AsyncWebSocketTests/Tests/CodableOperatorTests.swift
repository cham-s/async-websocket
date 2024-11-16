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
    
    let statuses = try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id,
        url: "ws://\(host)",
        port: port
      )
    )
    
    // Checks if a connected event has been emitted
    let didFail = LockIsolated<Bool>(false)
    let closeCode = LockIsolated<WebSocketErrorCode?>(nil)
    for await _ in statuses
      .on(
        \.connected,
         onDidClose: { code in
           closeCode.withValue { $0 =  code }
         },
         onDidFail: { _ in
           didFail.withValue { $0 = true }
           fatalError()
         }) {
      
      
      // Checks if the connection is active.
      #expect(await webSocketActor.connections.count == 1)
      
      // Checks if the connection is related to the current id.
      _ = try #require(
        await webSocketActor.connections.keys.first(where: { $0 == id })
      )
      
      /// Task handling the stream of frame logic.
      let messagesTask = Task {
        let frames = try await webSocketActor
          .receive(id: id)
          .success(of: Message.self)
        
        let getUsersTask = Task {
          let message = Message.request(
            .single(.getUsers(count: .two))
          )
          let data = try JSONEncoder().encode(message)
          try await webSocketActor.send(
            id: id,
            frame: .message(.binary(data))
          )
        }
        
        await Task.yield()
        _ = try await getUsersTask.value
        
        var messageIterator = frames.makeAsyncIterator()
        let expectedResponse = Message.response(
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
        #expect(await messageIterator.next() == expectedResponse)
      }
      
      await Task.yield()
      _ = try await messagesTask.value

      // Close the connection
      try await webSocketActor.send(
        id: id,
        frame: .close(code: .normalClosure)
      )
    }
    
    #expect(didFail.value == false)
    #expect(closeCode.value == .normalClosure)

    // Checks if the connection is closed.
    let isClosed = try await connectionIsClosed(webSocketActor, id: id)
    #expect(isClosed)
    
    // Checks if there is no more active connection inside the actor.
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
    
    let statuses = try await webSocketActor.open(
      settings: AsyncWebSocketClient.Settings(
        id: id,
        url: "ws://\(host)",
        port: port
      )
    )
    
    // Checks if a connected event has been emitted
    let didFail = LockIsolated<Bool>(false)
    let closeCode = LockIsolated<WebSocketErrorCode?>(nil)
    for await _ in statuses
      .on(
        \.connected,
         onDidClose: { code in
           closeCode.withValue { $0 =  code }
         },
         onDidFail: { _ in
           didFail.withValue { $0 = true }
           fatalError()
         }) {
      
      // Checks if the connection is active.
      #expect(await webSocketActor.connections.count == 1)
      
      // Checks if the connection is related to the current id.
      _ = try #require(
        await webSocketActor.connections.keys.first(where: { $0 == id })
      )
      
      /// Task handling the stream of frame logic.
      let responsesTask = Task {
        let responses = try await webSocketActor
          .receive(id: id)
          .success(of: Message.self)
          .case(\.response)
        
        /// Starts the stream of User.
        let startStreamTask = Task {
          let request = Message.request(.single(.startStream))
          let data = try JSONEncoder().encode(request)
          try await webSocketActor.send(
            id: id,
            frame: .message(.binary(data))
          )
        }
        
        await Task.yield()
        _ = try await startStreamTask.value
        
        /// Stops the stream of User.
        let stopStreamTask = Task {
          let request = Message.request(.single(.stopStream))
          let data = try JSONEncoder().encode(request)
          try await webSocketActor.send(
            id: id,
            frame: .message(.binary(data))
          )
        }
        
        await Task.yield()
        _ = try await stopStreamTask.value

        var responsesIterator = responses.makeAsyncIterator()
        #expect(await responsesIterator.next() == .success(.startStream))
        #expect(await responsesIterator.next() == .success(.stopStream))
      }
      
      await Task.yield()
      _ = try await responsesTask.value
      
      // Close the connection
      try await webSocketActor.send(
        id: id,
        frame: .close(code: .normalClosure)
      )
    }
    
    #expect(didFail.value == false)
    #expect(closeCode.value == .normalClosure)

    // Checks if the connection is closed.
    let isClosed = try await connectionIsClosed(webSocketActor, id: id)
    #expect(isClosed)
    
    // Checks if there is no more active connection inside the actor.
    #expect(await webSocketActor.connections.count == 0)
  }
}

extension Tag {
  @Tag static var codable: Self
}
