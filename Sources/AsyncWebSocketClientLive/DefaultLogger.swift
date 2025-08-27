import AsyncWebSocketClient
import Dependencies
import IssueReporting
import Logging

private enum DefaultWebSocketLoggerKey: DependencyKey {
  static var liveValue: Logger {
    Logging.Logger(label: "websocket-connection")
  }
}

public func mainLogger() -> Logger {
  Logging.Logger(label: "websocket-connection")
}

extension DependencyValues {
  var defaultWebSocketLogger: Logger {
    get { self[DefaultWebSocketLoggerKey.self] }
    set { self[DefaultWebSocketLoggerKey.self] = newValue }
  }
}

func log(
  option: AsyncWebSocketClient.LoggingOption,
  message: Logger.Message
) {
  @Dependency(\.defaultWebSocketLogger) var logger
  switch option {
  case .default:
    logger.debug(message)
  case .timed: break
    // TODO: Add
  }
}
