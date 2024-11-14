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
  ///   - onClose: A closure to invoke upon close..
  @inlinable
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
  ///   - onClose: A closure to invoke upon close..
  ///   - onDidFail: A closure to invoke upon failure..
  @inlinable
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

extension AsyncStream where Element: Sendable {
  /// Transforms a stream of Element into a stream of Result of transformed Element or Error.
  ///
  /// It allows the stream to continue even upon failure when attempting to transform the element.
  @inlinable
  public func toResult<T: Sendable>(
    transform: @Sendable @escaping (Element) throws -> T
  ) -> AsyncStream<Result<T, any Error>> {
    self
      .map { element in
        return Result { try transform(element) }
      }
      .eraseToStream()
  }
  
  public func resultCatchingFailure<T: Sendable>(
    transform: @Sendable @escaping (Element) throws -> T,
    operation: (@Sendable (any Error) -> Void )? = nil
  ) -> AsyncStream<T> {
    self
      .toResult(transform: transform)
      .compactMap {
        switch $0 {
        case let .success(success):
          return success
        case let .failure(error):
          operation?(error)
          return nil
        }
      }
      .eraseToStream()
  }
}

extension AsyncStream where Element == AsyncWebSocketClient.Frame {
  /// Attemps to decode into JSON if the frame is message.data or message.text.
  @inlinable
  public func json<T>(
    decoder: JSONDecoder = JSONDecoder(),
    of type: T.Type
  ) -> AsyncStream<Result<T, any Error>> where T: Codable, T: Sendable {
    self
      .on(\.message)
      .toResult {
        switch $0 {
        case let .binary(data):
          return try decoder.decode(T.self, from: data)
        case let .text(string):
          guard let data = string.data(using: .utf8) else {
            throw NSError(
              domain: "String To Data Conversion",
              code: 0,
              userInfo: ["reason": "Faield to convert string to data"]
            )
          }
          return  try JSONDecoder().decode(T.self, from: data)
        }
      }
  }
  
  /// Decodes incoming text and data frames into JSON ignoring failing conversion to JSON.
  @inlinable
  public func success<T>(
    decoder: JSONDecoder = JSONDecoder(),
    of type: T.Type
  ) -> AsyncStream<T> where T: Codable, T: Sendable {
    self
      .on(\.message)
      .resultCatchingFailure(transform: {
        switch $0 {
        case let .binary(data):
          return try decoder.decode(T.self, from: data)
        case let .text(string):
          guard let data = string.data(using: .utf8) else {
            throw NSError(
              domain: "String To Data Conversion",
              code: 0,
              userInfo: ["reason": "Faield to convert string to data"]
            )
          }
          return  try JSONDecoder().decode(T.self, from: data)
        }
      })
  }
}
