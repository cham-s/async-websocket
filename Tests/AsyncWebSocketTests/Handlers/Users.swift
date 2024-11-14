import Dependencies
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

final class UsersHandler: @unchecked Sendable, ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame
  
  let streamTask = LockIsolated<Task<Void, Error>?>(nil)
  
  @Dependency(\.continuousClock) var clock
  
  private var awaitingClose: Bool = false
  
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
        .whenComplete { _ in context.close(promise: nil) }
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

    case .text:
      do {
        let string = frameData.readString(length: frameData.readableBytes) ?? ""
        let data = string.data(using: .utf8)!
        let message = try JSONDecoder().decode(Message.self, from: data)
        self.handle(message, context: context)
      } catch {
        self.send(
          .response(.failure(.init(code: .invalidJSONFormat))),
          context: context
        )
      }
      
    case .binary:
      do {
        let data = frameData.readData(length: frameData.readableBytes) ?? Data()
        let message = try JSONDecoder().decode(Message.self, from: data)
        self.handle(message, context: context)
      } catch {
        self.send(
          .response(.failure(.init(code: .invalidJSONFormat))),
          context: context
        )
      }

    case .continuation, .pong:
//      print("ignoring continuation and pong frames")
      break
      
    default:
      print("Frame not handled: \(frame.opcode)")
    }
  }
  
  private func handle(
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
  
  private func handle(
    _ request: Request,
    context: ChannelHandlerContext
  ) {
    switch request {
    case let .getUsers(count):
      let response = Array([User].users.prefix(count.rawValue))
      self.send(
        .response(.success(.getUsers(.init(users: response)))),
        context: context
      )
    case .startStream:
      self.streamTask.withValue {
        $0 = Task {
          var index = 0
          for try await _ in self.clock.timer(interval: .seconds(1)) {
            self.send(
              .event(.newUser(.init(user: [User].users[index]))),
              context: context
            )
            index += 1
            if index > 2 {
              index = 0
            }
          }
        }
      }
    case .stopStream:
      self.streamTask.withValue {
        $0?.cancel()
        $0 = nil
        self.send(
          .response(.success(.stopStream)),
          context: context
        )
      }
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
  
  private func send(
    _ message: Message,
    context: ChannelHandlerContext
  ) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = .prettyPrinted
      let data = try encoder.encode(message)
      let frameData = context.channel.allocator.buffer(data: data)
      let frame = WebSocketFrame(fin: true, opcode: .binary, data: frameData)
      context.write(self.wrapOutboundOut(frame), promise: nil)
    } catch {
      print("Failed to encode json.")
    }
  }
}

