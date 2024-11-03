import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

final class WebSocketEchoHandler: ChannelInboundHandler {
  typealias InboundIn = WebSocketFrame
  typealias OutboundOut = WebSocketFrame
  
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
  
  private func pong(context: ChannelHandlerContext, frame: WebSocketFrame) {
    var frameData = frame.data
    let maskingKey = frame.maskKey
    
    if let maskingKey = maskingKey {
      frameData.webSocketUnmask(maskingKey)
    }
    
    let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
    context.write(self.wrapOutboundOut(responseFrame), promise: nil)
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
      self.pong(context: context, frame: frame)
      
    case .text, .binary, .pong, .continuation:
      let responseFrame = WebSocketFrame(fin: true, opcode: frame.opcode, data: frameData)
      context.write(self.wrapOutboundOut(responseFrame), promise: nil)
      
    default:
      let responseFrame = WebSocketFrame(fin: true, opcode: .binary, data: frameData)
      context.write(self.wrapOutboundOut(responseFrame), promise: nil)
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

final class EchoMessageHandler: ChannelInboundHandler {
  typealias InboundIn =  WebSocketFrame
  typealias OutboundOut = WebSocketFrame
  
  var awaitingClose = false
  
  public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let frame = self.unwrapInboundIn(data)
    self.onFrame(context: context, frame: frame)
  }
  
  public func channelReadComplete(context: ChannelHandlerContext) {
    context.flush()
  }
  
  
  private func onFrame( context: ChannelHandlerContext, frame: WebSocketFrame) {
    
    switch frame.opcode {
    case .connectionClose:
      self.onClose(context: context, frame: frame)
    case .ping:
      self.onPing(context: context, frame: frame)
    case .text:
      self.onText(context: context, frame: frame)
    default:
      self.onOther(context: context, frame: frame)
    }
  }
  
  private func onOther(context: ChannelHandlerContext, frame: WebSocketFrame) {
    let responseFrame = WebSocketFrame(
      fin: true,
      opcode: .text,
      data: .init(string: "Sorry, unhanadled frame, only text frames are allowed.")
    )
    context.write(self.wrapOutboundOut(responseFrame), promise: nil)
  }
  private func onText( context: ChannelHandlerContext, frame: WebSocketFrame) {
    var frameData = frame.data
    let maskingKey = frame.maskKey
    
    if let maskingKey = maskingKey {
      frameData.webSocketUnmask(maskingKey)
    }
    
    guard 
      let str = frameData.readString(length: frameData.readableBytes)
    else {
      let responseFrame = WebSocketFrame(
        fin: true,
        opcode: .text,
        data: .init(string: "Sorry, couldn't read the message.")
      )
      context.write(self.wrapOutboundOut(responseFrame), promise: nil)
      return
    }
    let responseFrame = WebSocketFrame(
      fin: true,
      opcode: .text,
      data: .init(string: "\(str) to you!")
    )
    context.write(self.wrapOutboundOut(responseFrame), promise: nil)
  }
  
  private func onClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
    if self.awaitingClose {
      context.close(promise: nil)
    }
    let closeFrame = WebSocketFrame(
      fin: true,
      opcode: .connectionClose,
      data: frame.unmaskedData
    )
    
    context.writeAndFlush(self.wrapOutboundOut(closeFrame))
       .whenComplete { _ in context.close(promise: nil) }
  }
  
  private func onPing( context: ChannelHandlerContext, frame: WebSocketFrame) {
    var frameData = frame.data
    let maskingKey = frame.maskKey
    
    if let maskingKey = maskingKey {
      frameData.webSocketUnmask(maskingKey)
    }
    
    let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
    context.write(self.wrapOutboundOut(responseFrame), promise: nil)
  }
}

let websocketResponse = """
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Swift NIO WebSocket Test Page</title>
    <script>
        var wsconnection = new WebSocket("ws://localhost:8888/websocket");
        wsconnection.onmessage = function (msg) {
            var element = document.createElement("p");
            element.innerHTML = msg.data;

            var textDiv = document.getElementById("websocket-stream");
            textDiv.insertBefore(element, null);
        };
    </script>
  </head>
  <body>
    <h1>WebSocket Stream</h1>
    <div id="websocket-stream"></div>
  </body>
</html>
"""

final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart
  
  private var responseBody: ByteBuffer!
  
  func handlerAdded(context: ChannelHandlerContext) {
    self.responseBody = context.channel.allocator.buffer(string: websocketResponse)
  }
  
  func handlerRemoved(context: ChannelHandlerContext) {
    self.responseBody = nil
  }
  
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    let reqPart = self.unwrapInboundIn(data)
    
    // We're not interested in request bodies here: we're just serving up GET responses
    // to get the client to initiate a websocket request.
    guard case .head(let head) = reqPart else {
      return
    }
    
    // GETs only.
    guard case .GET = head.method else {
      self.respond405(context: context)
      return
    }
    
    var headers = HTTPHeaders()
    headers.add(name: "Content-Type", value: "text/html")
    headers.add(name: "Content-Length", value: String(self.responseBody.readableBytes))
    headers.add(name: "Connection", value: "close")
    let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1),
                                        status: .ok,
                                        headers: headers)
    context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
    context.write(self.wrapOutboundOut(.body(.byteBuffer(self.responseBody))), promise: nil)
    context.write(self.wrapOutboundOut(.end(nil))).whenComplete { (_: Result<Void, any Error>) in
      context.close(promise: nil)
    }
    context.flush()
  }
  
  private func respond405(context: ChannelHandlerContext) {
    var headers = HTTPHeaders()
    headers.add(name: "Connection", value: "close")
    headers.add(name: "Content-Length", value: "0")
    let head = HTTPResponseHead(version: .http1_1,
                                status: .methodNotAllowed,
                                headers: headers)
    context.write(self.wrapOutboundOut(.head(head)), promise: nil)
    context.write(self.wrapOutboundOut(.end(nil))).whenComplete { (_: Result<Void, any Error>) in
      context.close(promise: nil)
    }
    context.flush()
  }
}
