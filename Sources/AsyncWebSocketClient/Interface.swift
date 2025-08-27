import CasePaths
import Foundation
import NIOWebSocket
import Tagged
import WebSocketKit

/// A client for facilitating asynchronous communication with a server using the WebSocket protocol.
///
public struct AsyncWebSocketClient: Sendable {
  /// Attempts to initiate a connection with the server.
  ///
  /// - Parameters:
  ///   - settings: Necessary configuration for setting up the connection with the server.
  /// - Returns: A stream of connection status.
  public var open: @Sendable (_ settings: Settings) async throws -> Void
  /// Starts to subscribe for incoming frames.
  ///
  /// - Parameters:
  ///   - id: A value used to identify the connection.
  /// - Returns: A stream of WebSocket frame.
  public var receive: @Sendable (_ id: ID) async throws -> AsyncStream<Frame>
  /// Sends a WebSocket frame to the other end of a communication.
  /// - Parameters:
  ///   - id: A value used to identify the connection.
  ///   - frame: The control frame to send to the the server.
  public var send: @Sendable (_ id: ID,_ frame: Frame) async throws -> Void
  
  /// The connection status with the server.
  /// - Parameters:
  ///   - id: A value used to identify the connection.
  /// - Returns: A boolean indicating if there is a connection or not.
  public var isConnected: @Sendable (_ id: ID) async throws -> Bool
  
  /// Instantiates a client to communicate with a server via the WebSocket protocol.
  /// - Parameters:
  ///   - open: Closure for attempting to initiate a connection.
  ///   - receive: Closure for starting  to subscribe for incoming frames.
  ///   - send: Closure for sending a WebSocket frame to the other end of a communication.
  ///   - isConnected: Closure for sending a WebSocket frame to the other end of a communication.
  public init(
    open: @escaping @Sendable (Settings) async throws -> Void,
    receive: @escaping @Sendable (ID) async throws -> AsyncStream<Frame>,
    send: @escaping @Sendable (ID, Frame) async throws -> Void,
    isConnected: @escaping @Sendable (_ id: ID) async throws -> Bool,
  ) {
    self.open = open
    self.receive = receive
    self.send = send
    self.isConnected = isConnected
  }
  
  /// Event sent / received by the client / server during the lifetime of a WebSocket connection.
  @CasePathable
  public enum Frame: Sendable, Equatable {
    /// A message to be sent or received by the server or the client.
    case message(Message)
    /// A ping control frame to be sent or received by the server or the client.
    case ping(Data = Data())
    /// A pong control frame  to be sent or received by the server or the client.
    case pong(Data = Data())
    /// A close control frame  to be sent or received by the server or the client.
    ///
    /// Closes the connection between the client and the server.
    case close(code: WebSocketErrorCode)
  }
  
  /// Message to be sent or received.
  @CasePathable
  public enum Message: Sendable, Equatable {
    /// A collection of raw bytes.
    case binary(Data)
    /// String form.
    case text(String)
  }
  
  public enum LoggingOption: Sendable {
    case `default`
    case timed
  }
  
  /// Configuration values to be used when establishing the connection with the server.
  public struct Settings: Sendable {
    public let id: ID
    public let url: String
    public let port: Int?
    public let configuration: WebSocketKit.WebSocketClient.Configuration
    public let headers: HTTPHeaders
    public let pingInterval: TimeInterval?
    public let loggingOption: LoggingOption?
    
    /// Creates a configuration for initiating a connection.
    /// - Parameters:
    ///   - id: Identifier for the connection.
    ///   - url: Endpoint URL.
    ///   - port: Endpoint port.
    ///   - configuration: Configuration.
    ///   - headers: HTTP headers.
    ///   - pingInterval: Interval in which a ping is sent to check if the connection is still alive.
    public init(
      id: ID,
      url: String,
      port: Int? = nil,
      configuration: WebSocketKit.WebSocketClient.Configuration = .init(),
      headers: HTTPHeaders = [:],
      pingInterval: TimeInterval? = nil,
      loggingOption: LoggingOption? = .default
    ) {
      self.id = id
      self.url = url
      self.port = port
      self.headers = headers
      self.configuration = configuration
      self.pingInterval = pingInterval
      self.loggingOption = loggingOption
    }
  }
  
  /// An event representing the status of the connection.
  @CasePathable
  public enum ConnectionStatus: Sendable, Equatable {
    /// A connection has been established.
    case connected
    /// Performing routine operations in order to establish a connection whith the other other end of the communication.
    case connecting
    /// Connection with the server did end.
    case didClose(WebSocketErrorCode)
    /// Failed to established a connection
    case didFail(NSError)
    /// No connection established.
    case disconnected
  }
  
  /// A type used to identify the connection with the server.
  public typealias ID = Tagged<Self, UUID>
}
