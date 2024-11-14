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
