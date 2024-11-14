//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2021 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

extension ChannelHandlerContext: @unchecked @retroactive Sendable { }

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
