import DequeModule
import AsyncStreamTypes
import CasePaths
import Dependencies
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import Observation

/// The runtime responsible for checking that each request received will be treated as a response in the same order.
final actor ServerRuntime {
  @Dependency(\.continuousClock) var clock
  
  var expectedOrder: Deque<UUID> = []
  var requests: Deque<InternalRequest> = [] {
    didSet {
      if let request = requests.popLast() {
//        print("popping request: \(request.request)")
        self.handle(request)
      }
    }
  }
  var responses: Deque<InternalMessage> = []

  /// The general task for listening for incoming requests.
  var runTask: Task<Void, Error>? = nil
  var streamTask: Task<Void, Never>? = nil
  
  func shutdown() {
    self.streamTask?.cancel()
    self.streamTask = nil
    self.runTask?.cancel()
    self.runTask = nil
  }
  
  private func handle(
    _ request: InternalRequest
  ) {
    switch request.request {
    case let .getUsers(count):
      let response = Array([User].users.prefix(count.rawValue))
      let message = Message.response(.success(.getUsers(.init(users: response))))
      self.submit(InternalMessage(request: request, message: message))

    case .startStream:
      self.startStream(request: request, context: request.context)
    case .stopStream:
      self.stopStream(request: request, context: request.context)
    }
  }
  
  private func startStream(
    request: InternalRequest,
    context: ChannelHandlerContext
  ) {
    self.streamTask = Task {

      let message = Message.response(.success(.startStream))
      self.submit(InternalMessage(request: request, message: message))
    }
  }
  
  private func stopStream(
    request: InternalRequest,
    context: ChannelHandlerContext
  ) {
    self.streamTask?.cancel()
    self.streamTask = nil
    let message = Message.response(.success(.stopStream))
    self.submit(InternalMessage(request: request, message: message))
  }

  /// Sends a ``Message`` to the client.
  nonisolated private func send(
    _ message: Message,
    context: ChannelHandlerContext
  ) {
    do {
//      print("Sending message: \(message)")
      let encoder = JSONEncoder()
      encoder.outputFormatting = .prettyPrinted
      let data = try encoder.encode(message)
      context.eventLoop.execute {
        let frameData = context.channel.allocator.buffer(data: data)
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: frameData)
        context.writeAndFlush(NIOAny(frame), promise: nil)
      }
    } catch {
      print("Failed to encode json.")
    }
  }
  
  func handle(
    _ message: Message,
    context: ChannelHandlerContext
  ) {
    
    switch message {
    case let .request(request):
      self.handle(request, context: context)
    case .response, .event:
      // ignoring client side cases.
      break
    }
  }
  
  /// Each request received from a client is piped through the request stream to be treated by order of appeareance.
  private func handle(
    _ request: Request,
    context: ChannelHandlerContext
  ) {
    switch request {
    case let .single(request):
      let id = UUID()
      self.expectedOrder.prepend(id)
      self.requests.prepend(
        InternalRequest(
          id: id,
          date: Date(),
          request: request,
          context: context
        )
      )
    case let .batch(requests):
      requests.forEach {
        let id = UUID()
        self.expectedOrder.prepend(id)
        self.requests.prepend(
          InternalRequest(
            id: id,
            date: Date(),
            request: $0,
            context: context
          )
        )
      }
    }
  }
  
  func start() {
    self.runTask = Task {
      while !Task.isCancelled {
        try await Task.sleep(nanoseconds: 50)
        guard
          let id = self.expectedOrder.last,
          let message = self.responses.first(where: { $0.id == id })
        else {
          continue
        }
        self.send(message.message, context: message.context)
        self.expectedOrder.removeLast()
        self.responses.removeAll(where: { $0.id == id })
      }
    }
  }
  
  func handleFrame(
    _ frameData: ByteBuffer,
    context: ChannelHandlerContext,
    isText: Bool
  ) {
    do {
      var frameData = frameData
      var data: Data
      if isText {
        let string = frameData.readString(length: frameData.readableBytes) ?? ""
        data = string.data(using: .utf8)!
      } else {
        data = frameData.readData(length: frameData.readableBytes) ?? Data()
      }
      let message = try JSONDecoder().decode(Message.self, from: data)
      self.handle(message, context: context)
    } catch {
      let message = Message.response(.failure(.init(code: .invalidJSONFormat)))
      let id = UUID()
      self.expectedOrder.prepend(id)
      self.submit(
        InternalMessage(id: id, date: Date(), message: message, context: context)
      )
    }
  }
  
  private func submit(_ message: InternalMessage) {
//    print("Submitting: \(message)")
    self.responses.prepend(message)
  }
}

struct InternalRequest: Sendable {
  let id: UUID
  let date: Date
  let request: Request.RequestType
  let context: ChannelHandlerContext
  
  init(
    id: UUID,
    date: Date,
    request: Request.RequestType,
    context: ChannelHandlerContext
  ) {
    self.id = id
    self.date = date
    self.request = request
    self.context = context
  }
}

struct InternalMessage: Sendable {
  let id: UUID
  let date: Date
  let message: Message
  let context: ChannelHandlerContext
  
  init(
    id: UUID,
    date: Date,
    message: Message,
    context: ChannelHandlerContext
  ) {
    self.id = id
    self.date = date
    self.message = message
    self.context = context
  }
  
  init(
    request: InternalRequest,
    message: Message
  ) {
    self.id = request.id
    self.date = request.date
    self.message = message
    self.context = request.context
  }
}

/// Test server that emits User based on requests.
final class UsersHandler: @unchecked Sendable, ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame
  
  var serverRuntime = ServerRuntime()
  private var awaitingClose: Bool = false
  
  public func handlerAdded(context: ChannelHandlerContext) {
    Task { await self.serverRuntime.start() }
  }
  
  public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = self.unwrapInboundIn(data)
    self.frame(context: context, frame: frame)
  }
  
  public func channelReadComplete(context: ChannelHandlerContext) {
    context.flush()
  }
  
  private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
    // Handle a received close frame. In websockets, we're just going to send the close
    // frame and then close, unless we already sent our own close frame.
    if awaitingClose {
      // Cool, we started the close and were waiting for the user. We're done.
      context.close(promise: nil)
    } else {
      let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)
     context.writeAndFlush(self.wrapOutboundOut(closeFrame))
        .whenComplete { _ in
          context.close(promise: nil)
        }
    }
  }
  
  private func frame(
    context: ChannelHandlerContext,
    frame: WebSocketFrame
  ) {
    var frameData = frame.data
    let maskingKey = frame.maskKey
    
    if let maskingKey = maskingKey {
      frameData.webSocketUnmask(maskingKey)
    }
    
    switch frame.opcode {
    case .connectionClose:
      self.receivedClose(context: context, frame: frame)
    case .ping:
      let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
      context.write(self.wrapOutboundOut(responseFrame), promise: nil)

    case .text, .binary:
      Task {
        await self.serverRuntime.handleFrame(
          frameData,
          context: context,
          isText: frame.opcode == .text
        )
      }

    case .continuation, .pong:
//      print("ignoring continuation and pong frames")
      break
      
    default:
      print("Frame not handled: \(frame.opcode)")
    }
  }
  
  private func closeOnError(context: ChannelHandlerContext) {
    // We have hit an error, we want to close. We do that by sending a close frame and then
    // shutting down the write side of the connection.
    var data = context.channel.allocator.buffer(capacity: 2)
    data.write(webSocketErrorCode: .protocolError)
    let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
    context.write(self.wrapOutboundOut(frame)).whenComplete { (_: Result<Void, any Error>) in
      context.close(mode: .output, promise: nil)
    }
    awaitingClose = true
  }
}

