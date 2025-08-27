import AsyncStreamTypes
import Dependencies
import Foundation
import NIOCore
import NIOPosix
import AsyncWebSocketClient
import WebSocketKit
import Logging

extension AsyncWebSocketClient: DependencyKey {
  /// Default live implementatin of the client.
  public static var liveValue: Self {
    Self(
      open: { try await WebSocketActor.shared.open(settings: $0) },
      receive: { try await WebSocketActor.shared.receive(id: $0) },
      send: { try await WebSocketActor.shared.send(id: $0, frame: $1) },
      isConnected: { try await WebSocketActor.shared.isConnected(id: $0) }
    )
  }
  
  /// An actor for handling the logic for the live implementation of the AsyncWebSocketClient.
  final actor WebSocketActor: Sendable, GlobalActor {
    /// State of the connection.
    struct Connection {
      var webSocket: WebSocket?
      var frameStream: AsyncStreamTypes.Stream<Frame>?
    }
    
    /// EventLoop group to be used during the connection with the server.
    var eventLoopGroup: MultiThreadedEventLoopGroup? = nil
    /// A collection of connections.
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
    
    // TODO: Rework on the open to make cleaner
    /// Attempts to Initiate a connection with the server.
    public func open(
      settings: Settings
    ) async throws {
      if Task.isCancelled {
        throw WebSocketError.taskCancelled
      }
      
      if let logOption = settings.loggingOption {
        var portString: String
        if let port = settings.port {
          portString = "\(port)"
        } else {
          portString = "Unspecified"
        }
        let message = Logger.Message("Starting connection for URI: \(settings.url) with port: \(portString)")
        log(option: logOption, message: message)
      }
      
      guard self.connections[settings.id] == nil else {
        if let logOption = settings.loggingOption {
          let message = Logger.Message("Connection already opened for URI: \(settings.url) with port: \(settings.port.portString)")
          log(option: logOption, message: message)
        }
        throw WebSocketError.alreadyOpened(id: settings.id)
      }
      
      // TODO: Clean log repetition code
      guard !settings.url.isEmpty
      else {
        if let logOption = settings.loggingOption {
          let message = Logger.Message("An empty URL field was provided")
          log(option: logOption, message: message)
        }
        throw WebSocketError.emptyURLField
      }
      
      let urlString = "\(settings.url)\(settings.port == nil ? "" : ":\(settings.port!)")"
      
      guard
        urlString.hasWebSocketScheme,
        let url = URL(string: urlString)
      else {
        if let logOption = settings.loggingOption {
          let message = Logger.Message("Invalid WebSocket format for URI: \(settings.url) with port: \(settings.port.portString)")
          log(option: logOption, message: message)
        }
        throw WebSocketError.invalidWebSocketURLFormat
      }
      
      // Note: brackground task added to avoid thread inversion purple warning.
      let elg = await Task.detached(priority: .background) {
        MultiThreadedEventLoopGroup.singleton
      }.value
      
      if Task.isCancelled {
        try await self.eventLoopGroup?.shutdownGracefully()
      }
      
      self.eventLoopGroup = elg
      let frame = self.makeFrame(id: settings.id)
      let socketStream = AsyncStream<WebSocket>.makeStream()
      
      try await connect(
        url: url,
        settings: settings,
        frame: frame,
        socketContinuation: socketStream.continuation,
        group: elg
      )
      
      // Waits to make sure the connection is added to the collection during the
      // onUpgrade closure from the WebSocket.connect initializer.
      // Otherwise it returns confirming the connection to HTTP but not the upgrade to
      // WebSocket which is the second phase of the process.
      for await webSocket in socketStream.stream {
        connections[settings.id] = Connection(webSocket: webSocket, frameStream: frame)
      }
      try await self.checkCancelltionToCloseResources(id: settings.id)
    }
    
    
    /// Starts to subscribe for incoming frames.
    /// - Parameters:
    ///   - id: A value used to identify the connection.
    /// - Returns: A stream of WebSocket frame.
    func receive(id: ID) async throws -> AsyncStream<Frame> {
      guard let _ = self.connections[id] else {
        throw WebSocketError.connectionClosed
      }
      
      if let frame =  self.connections[id]?.frameStream?.stream {
        return frame
      } else {
        let newFrame = self.makeFrame(id: id)
        self.connections[id]?.frameStream = newFrame
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
    
    /// The connection status with the server.
    /// - Parameters:
    ///   - id: A value used to identify the connection.
    /// - Returns: A boolean indicating if there is a connection or not.
    public func isConnected(id: ID) async throws -> Bool {
      do {
        let connection = try connection(for: id)
        guard let websocket = connection.webSocket
        else { return false }
        return !websocket.isClosed
      } catch {
        return false
      }
    }
    
    /// Initializes the connection.
    ///
    /// Register callbacks for different WebSocket events.
    private func connect(
      url: URL,
      settings: Settings,
      frame: AsyncStreamTypes.Stream<Frame>,
      socketContinuation: AsyncStream<WebSocket>.Continuation,
      group: MultiThreadedEventLoopGroup
    ) async throws {
      // TODO: Check for scheme, host, port logic before force unwrap
      let client = WebSocketClient(eventLoopGroupProvider: .shared(group))
      try await client.connect(
        scheme: url.scheme!,
        host: url.host!,
        port: url.port!
      ) { webSocket in
        
        webSocket.pingInterval = settings.pingInterval.map {
          TimeAmount.seconds(Int64($0))
        }
        
        // Captures the websocket and sends it to the open function
        socketContinuation.yield(finalValue: webSocket)
        
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
            frame.continuation.yield(
              finalValue: .close(code: webSocket.closeCode ?? .unexpectedServerError)
            )
          }
      }.get()
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
    
    /// Picks a connection from the list.
    private func connection(for id: ID) throws -> Connection {
      guard let connection = self.connections[id]
      else { throw WebSocketError.connectionClosed }
      return connection
    }
    
    /// Removes a connection from the list.
    private func removeConnection(for id: ID) {
      self.connections[id]?.frameStream = nil
      self.connections[id]?.webSocket = nil
      self.connections[id] = nil
    }
    
    /// `Nils` out the frame field from a connection.
    private func nilOutFrame(id: ID) {
      self.connections[id]?.frameStream = nil
    }
    
    /// Closes the connection with the server.
    private func close(id: ID) async throws {
      try await self.connections[id]?.webSocket?.close(code: .goingAway)
    }
    
    /// Constructs a frame AsyncSequence with a custom onTermination closure.
    private func makeFrame(id: ID) -> AsyncStreamTypes.Stream<Frame> {
      if let frame = self.connections[id]?.frameStream {
        return frame
      }
      
      let frame = AsyncStream<Frame>.makeStream()
      frame.continuation.onTermination = { _ in
        Task {
          await self.nilOutFrame(id: id)
          try await self.close(id: id)
          await self.removeConnection(for: id)
          try await self.eventLoopGroup?.shutdownGracefully()
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

private extension Optional where Wrapped == Int {
  var portString: String {
    switch self {
    case .none: "Unspecified"
    case let .some(port): String(port)
    }
  }
}
