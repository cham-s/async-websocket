import AsyncWebSocketClient
import CasePaths
import ConcurrencyExtras
import Foundation
import NIOWebSocket

#if swift(>=6.0)
extension KeyPath: @unchecked @retroactive Sendable {}
#else
extension KeyPath: @unchecked Sendable {}
#endif

extension AsyncStream where Element == AsyncWebSocketClient.Frame {
  /// Listens for a particular event among many cases of an enum and subscribes to its associated value.
  ///
  /// If no associated value is available Void is emitted.
  ///  - Parameters:
  ///   - status: A CaseKeyPath for accessing the desired frame.
  ///   - onClose: A closure to invoke uppon close..
  public func on<Value>(
    _ frame: CaseKeyPath<AsyncWebSocketClient.Frame, Value>,
    onClose: (@Sendable (WebSocketErrorCode) async -> Void)? = nil
  ) -> AsyncStream<Value> {
    self.compactMap {
      if
        let code = $0[case: \.close],
        let task = onClose {
        await task(code)
      }
      return $0[case: frame]
    }.eraseToStream()
  }
}
  
extension AsyncStream where Element == AsyncWebSocketClient.ConnectionStatus {
  /// Listens for a particular event among many cases of an enum and subscribes to its associated value.
  ///
  /// If no associated value is available Void is emitted.
  ///  - Parameters:
  ///   - status: A CaseKeyPath for accessing the desired status.
  ///   - onClose: A closure to invoke uppon close..
  ///   - onDidFail: A closure to invoke uppon failure..
  public func on<Value>(
    _ status: CaseKeyPath<AsyncWebSocketClient.ConnectionStatus, Value>,
    onDidClose: (@Sendable (WebSocketErrorCode) async -> Void)? = nil,
    onDidFail: (@Sendable (NSError) async -> Void)? = nil
  ) -> AsyncStream<Value> {
    self.compactMap {
      if
        let code = $0[case: \.didClose],
        let didClose = onDidClose {
        await didClose(code)
      } else if
        let error = $0[case: \.didFail],
        let didFail = onDidFail {
        await didFail(error)
      }
      return $0[case: status]
    }.eraseToStream()
  }
}

