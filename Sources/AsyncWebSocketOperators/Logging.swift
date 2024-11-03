import AsyncWebSocketClient
import CustomDump
import Logging

extension AsyncWebSocketClient.ConnectionStatus {
  /// String representation of the status.
  public var asString: String {
    switch self {
    case .connected:
      return "Connected"
    case .connecting:
      return "Connecting..."
    case .didFail:
      return "Failure"
    case .didClose:
      return "Closed"
    }
  }
  
  public var customDump: String {
    String(customDumping: self)
  }
}

extension AsyncWebSocketClient.Frame {
  /// String representation of the frame.
  public var asString: String {
    switch self {
    case .message(.text):
      return "Message.text"
    case .message(.binary):
      return "Message.binary"
    case .ping:
      return "ping"
    case .pong:
      return "pong"
    case .close:
      return "close"
    }
  }
  
  public var customDump: String {
    String(customDumping: self)
  }
}

extension AsyncStream where Self.Element == AsyncWebSocketClient.Frame {
  /// Adds logging capability by logging every occuring event.
  ///  - parameters:
  ///  - action: A closure that prodives the current received for performing a logging action.
  public func log(
    action: (@Sendable (AsyncWebSocketClient.Frame) -> Void)? = nil
  ) -> Self {
    return self.map { element in
      action?(element)
      ?? defaultLogger(label: "com.async-webosocket-frame", dumping: element)
      return element
    }.eraseToStream()
  }
}

extension AsyncStream where Self.Element == AsyncWebSocketClient.ConnectionStatus {
  /// Adds logging capability by logging every occuring event.
  ///  - parameters:
  ///  - action: A closure that prodives the current received for performing a logging action.
  public func log(action: (@Sendable (AsyncWebSocketClient.ConnectionStatus) -> Void)? = nil) -> Self {
    return self.map { element in
      action?(element)
      ?? defaultLogger(label: "com.async-webosocket-connection", dumping: element)
      return element
    }.eraseToStream()
  }
}

/// Default logging behaviour.
///
/// Provides the default behaviour of logging using the `info` level by dumping the corresponding type to the console.
private func defaultLogger<T>(
  label: String,
  dumping: T
) {
  let logger = Logging.Logger(label: label)
  logger.info(": \(String(customDumping: dumping))")
}
