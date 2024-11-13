import AsyncStreamTypes
import Dependencies
import Foundation
import NIOCore
import NIOPosix
import AsyncWebSocketClient
import WebSocketKit

extension AsyncWebSocketClient: DependencyKey {
  /// Default live implementatin of the client.
  public static var liveValue: Self {
    Self(
      open: { try await WebSocketActor.shared.open(settings: $0) },
      receive: { try await WebSocketActor.shared.receive(id: $0) },
      send: { try await WebSocketActor.shared.send(id: $0, frame: $1) }
    )
  }

  /// Instance to be used during tests.
  ///
  /// Closures are marked as unimplemented they will trigger a failure if invoked during tests.
  public static let testValue: AsyncWebSocketClient = Self(
    open: unimplemented("\(Self.self).open"),
    receive: unimplemented("\(Self.self).receive"),
    send: unimplemented("\(Self.self).send")
  )
  
  /// An actor for handling the logic for the live implementation of the AsyncWebSocketClient.
  final actor WebSocketActor: Sendable, GlobalActor {
    typealias Connection = (
      webSocket: WebSocket?,
      frame: AsyncStreamTypes.Stream<Frame>?,
      status: AsyncStreamTypes.Stream<ConnectionStatus>?
    )
    
    /// EventLoop group to be used during the connection with the server.
    var eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    /// A list of all current running connections.
    var connections: [ID: Connection] = [:]
    /// A shared instance of the actor.
    static public let shared = WebSocketActor()
    
    /// An type that represents the error to be thrown after an operation with the dependency failed.
    enum WebSocketError: Error, Equatable {
      /// The client tries to perform a communication operation on a closed connection.
      case connectionClosed
      /// The client tries to reoopen an already opened connection.
      case alreadyOpened(id: ID)
      /// The url field from the configuration is empty.
      case emptyURLField
      /// Invalid URL format.
      ///
      /// A valid URI should starts with `ws://` or `wss://`.
      case invalidWebSocketURLFormat
      /// The caller cancelled the current task.
      case taskCancelled
    }
    
    /// Attempts to Initiate a connection with the server.
    public func open(
      settings: Settings
    ) async throws -> AsyncStream<ConnectionStatus> {
      if Task.isCancelled {
        throw WebSocketError.taskCancelled
      }
      
      guard self.connections[settings.id] == nil else {
        throw WebSocketError.alreadyOpened(id: settings.id)
      }
      
      guard !settings.url.isEmpty
      else { throw WebSocketError.emptyURLField }
      
      let urlString = "\(settings.url)\(settings.port == nil ? "" : ":\(settings.port!)")"
      
      guard
        urlString.hasWebSocketScheme,
        let url = URL(string: urlString)
      else { throw WebSocketError.invalidWebSocketURLFormat }
      
      // Note: brackground task added to avoid thread inversion purple warning.
      let elg = await Task.detached(priority: .background) {
        MultiThreadedEventLoopGroup.singleton
      }.value
      
      if Task.isCancelled {
        try await self.eventLoopGroup?.shutdownGracefully()
      }
      
      self.eventLoopGroup = elg
      let frame = self.makeFrame(id: settings.id)
      let status = self.makeStatus(id: settings.id)

      self.connect(
        id: settings.id,
        url: url,
        settings: settings,
        frame: frame,
        status: status,
        group: elg
      )
      
      try await self.checkCancelltionToCloseResources(id: settings.id)
      return status.stream
    }
    
    /// Handles the logic for yielding inicoming frames.
    private func connect(
      id: ID,
      url: URL,
      settings: Settings,
      frame: AsyncStreamTypes.Stream<Frame>,
      status: AsyncStreamTypes.Stream<ConnectionStatus>,
      group: MultiThreadedEventLoopGroup
    ) {
      status.continuation.yield(.connecting)
      WebSocket.connect(
        to: url,
        headers: settings.headers,
        configuration: settings.configuration,
        on: group
      ) { webSocket in
        
        webSocket.pingInterval = settings.pingInterval.map {
          TimeAmount.seconds(Int64($0))
        }
        
        Task {
          await self.add(
            webSocket,
            id: id,
            frame: frame,
            status: status
          )
        }
        
        webSocket.onText { _, text in
          frame.continuation.yield(.message(.text(text)))
        }
        webSocket.onBinary { _, byteBuffer in
          var buffer = byteBuffer
          let data = buffer.readData(length: buffer.readableBytes) ?? Data()
          frame.continuation.yield(.message(.binary(data)))
        }
        webSocket.onPing { _, byteBuffer in
          var buffer = byteBuffer
          let data = buffer.readData(length: buffer.readableBytes)
          frame.continuation.yield(.ping(data ?? Data()))
        }
        webSocket.onPong { _, byteBuffer in
          var buffer = byteBuffer
          let data = buffer.readData(length: buffer.readableBytes)
          frame.continuation.yield(.pong(data ?? Data()))
        }
        
        webSocket.onClose
          .whenComplete { _ in
            status.continuation.yield(
              .didClose(
                webSocket.closeCode ?? .unexpectedServerError
              )
            )
            frame.continuation.yield(
              .close(
                code: webSocket.closeCode ?? .unexpectedServerError
              )
            )
            frame.continuation.finish()
            status.continuation.finish()
          }
      }
      .whenComplete { result in
        switch result {
        case .success:
          status.continuation.yield(.connected)
        case let .failure(error):
          status.continuation.yield(finalValue: .didFail(error as NSError))
        }
      }
    }
    
    /// Starts to subscribe for incoming frames.
    /// - Parameters:
    ///   - id: A value used to identify the connection.
    /// - Returns: A stream of WebSocket frame.
    func receive(id: ID) async throws -> AsyncStream<Frame> {
      guard let _ = self.connections[id] else {
        throw WebSocketError.connectionClosed
      }
      
      if let frame =  self.connections[id]?.frame?.stream {
        return frame
      } else {
        let newFrame = self.makeFrame(id: id)
        self.connections[id]?.frame = newFrame
        return newFrame.stream
      }
    }
    
    /// Sends a WebSocket frame, to the other end of a communication.
    /// Tries to send an event to the server.
    /// - Parameters:
    ///   - id: A value used to identify the connection.
    ///   - frame: The control frame to send to the the server.
    func send(
      id: ID,
      frame: Frame
    ) async throws {
      
      let connection = try self.connection(for: id)
      
      switch frame {
      case let .message(.binary(data)):
        try await connection.webSocket?.send(
          raw: data,
          opcode: .binary,
          fin: true
        )
      case let .message(.text(text)):
        try await connection.webSocket?.send(text)
      case let .ping(data):
        try await connection.webSocket?.sendPing(data)
      case let .pong(data):
        try await connection.webSocket?.send(
          raw: data,
          opcode: .pong,
          fin: true
        )
      case let .close(code):
        try await connection.webSocket?.close(code: code)
        self.removeConnection(for: id)
      }
    }
    
    private func checkCancelltionToCloseResources(
      id: AsyncWebSocketClient.ID
    ) async throws {
      if Task.isCancelled {
        try await self.eventLoopGroup?.shutdownGracefully()
        self.removeConnection(for: id)
        throw WebSocketError.taskCancelled
      }
    }
    
    /// Adds a WebSocket object to the list of connection.
    private func add(
      _ webSocket: WebSocket,
      id: ID,
      frame: AsyncStreamTypes.Stream<Frame>,
      status: AsyncStreamTypes.Stream<ConnectionStatus>
    ) {
      self.connections[id] = (
        webSocket,
        frame,
        status
      )
    }
    
    /// Picks a connection from the list.
    private func connection(for id: ID) throws -> Connection {
      guard let connection = self.connections[id]
      else { throw WebSocketError.connectionClosed }
      return connection
    }
    
    /// Removes a connection from the list.
    private func removeConnection(for id: ID) {
      self.connections[id]?.frame = nil
      self.connections[id]?.status = nil
      self.connections[id]?.webSocket = nil
      self.connections[id] = nil
    }
    
    /// `Nils` out the frame field from a connection.
    private func nilOutFrame(id: ID) {
      self.connections[id]?.frame = nil
    }
    
    /// Closes the connection with the server.
    private func close(id: ID) async throws {
      try await self.connections[id]?.webSocket?.close(code: .goingAway)
    }
    
    /// Constructs a status AsyncSequence with a custom onTermination closure.
    private func makeStatus(id: ID) -> AsyncStreamTypes.Stream<ConnectionStatus> {
      let status = AsyncStream<ConnectionStatus>.makeStream()
      status.continuation.onTermination = { _ in
        Task {
          try await self.close(id: id)
          await self.removeConnection(for: id)
          try await self.eventLoopGroup?.shutdownGracefully()
        }
      }
      return status
    }
    
    /// Constructs a frame AsyncSequence with a custom onTermination closure.
    private func makeFrame(id: ID) -> AsyncStreamTypes.Stream<Frame> {
      if let frame = self.connections[id]?.frame {
        return frame
      }
      
      let frame = AsyncStream<Frame>.makeStream()
      frame.continuation.onTermination = { _ in
        Task {
          await self.nilOutFrame(id: id)
        }
      }
      return frame
    }
  }
}

extension DependencyValues {
  /// A client dependency to asynchronously communicate with a WebSocket server.
  ///
  /// Subscription is done through the use of an ``AsyncSequence``.
  public var webSocket: AsyncWebSocketClient {
    get { self[AsyncWebSocketClient.self] }
    set { self[AsyncWebSocketClient.self] = newValue }
  }
}

extension AsyncWebSocketClient {
  /// Default implementation of a client interacting with a live WebSocket server.
  public static let `default` = Self.liveValue
}
