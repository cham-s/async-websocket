extension String {
  /// Checks if a string starts with `ws://` or `wss://`.
  public var hasWebSocketScheme: Bool {
    self.hasPrefix("ws://") || self.hasPrefix("wss://")
    ? true
    : false
  }
}
