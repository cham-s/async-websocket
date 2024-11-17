# Async Websocket

> [!WARNING]
> 
> Please be aware that this package is experimental, integration in a production code should be carefully considered. 

## Overview

A client for handling commumication via the WebSocket protocol using Swift `async await` construct.

## Contents

- [Preview](#preview)

- [Getting started](#getting-started)

- [More examples](#more-examples)

- [Things to be aware of](#aware-of)

- [Credits and inspirations](#credits)

- [Feedback](#feedback)

## Preview <a name="preview"></a>

What makes the the client interesting is the use of operators to ease the transition between an incoming frame and a type that is easier to work with inside Swift.

`Incoming Websocket frame -> (Operator) -> Swift type`

At the end we have transformation from a stream of WebSocket frame into a Swfit type that is related to our code base.

Here is a presentation of the operators assuming we have a code base where the server and the client share the same models as way of communication shaped as follow:

<details>

<summary>Full Models</summary>

```swift
import CasePaths

struct User: Sendable, Codable, Equatable {
  let id: Int
  let name: String
}

enum Count: Int, Codable, Sendable, Equatable {
  case one = 1
  case two
  case three
}

extension Array where Element == User {
  static let users: Self = [.a, .b, .c]
}

extension User {
  static let a = Self(id: 1, name: "A")
  static let b = Self(id: 2, name: "B")
  static let c = Self(id: 3, name: "C")
}

struct GetUsersRequest: Codable, Sendable, Equatable {
  let count: Count

  init(count: Count) {
    self.count = count
  }
}

@CasePathable
enum Request: Codable, Sendable, Equatable {
  case single(RequestType)
  case batch([RequestType])

  @CasePathable
  enum RequestType: Codable, Sendable, Equatable {
    case getUsers(count: Count)
    case startStream
    case stopStream
  }
}

struct GetUsersResponse: Codable, Sendable, Equatable {
  let users: [User]

  init(users: [User]) {
    self.users = users
  }
}

@CasePathable
enum Response: Codable, Sendable, Equatable {
  case getUsers(GetUsersResponse)
  case startStream
  case stopStream

  @CasePathable
  enum Result: Codable, Sendable, Equatable {
    case success(Response)
    case failure(RequestError)
  }
}

struct RequestError: Codable, Sendable, Equatable {
  let code: ErrorCode
  let reason: String?

  init(
    code: ErrorCode,
    reason: String? = nil
  ) {
    self.code = code
    self.reason = reason
  }
}

struct NewUserEvent: Codable, Sendable, Equatable {
  let user: User

  init(user: User) {
    self.user = user
  }
}

@CasePathable
enum Event: Codable, Sendable, Equatable {
  case newUser(NewUserEvent)
  case streamStarted
  case streamStopped
}

@CasePathable
enum ErrorCode: Codable, Sendable, Equatable {
  case invalidJSONFormat
  case internalServerError
  case streamAlreadyStarted
  case streamNotStarted
}

@CasePathable
enum Message: Codable, Sendable, Equatable {
  case request(Request)
  case response(Response.Result)
  case event(Event)
}
```

</details>

</details>

## Operators

- [`json`](#json)

- [`success`](#success)

- [`case`](#case)

- [`field`](#field)

### `json`<a name="json"></a>

The `json` operator only focuses on the `message.binary` and the `message.text` WebSocket frame and ignores the rest.

It attemps to parse the `binary` or the `text` frame into the given `Type` and returns the result as a `Result<Type, any Error>`.

At the end we get an `AsyncStream<Result<<Type, any Error>>`

```swift
let results = try await webSocket
 .receive(id)
 .json(of: Message.self) // By default the decoder is initialized as JSONDecoder()

// results is of type AsyncStream<Result<Message, any Error>>
for await result in results {
  switch result {
    case let .success(message):
    print("Succeeded: (message)")
    case let .failure(error):
    print("Failed: (error)")  
  }
}
```

### `success`<a name="success"></a>

The `success` operator only focuses on the success case of the JSON decoding operation and ignores all failures.

```swift
let messages = try await webSocket
  .receive(id)
  .success(of: Message.self) // By default the decoder used is initialized is the JSONDecoder()

// messages is of type AsyncStream<Message>
for await message in messages {
  switch message {
  case let .request(request):
    print("We received a request: \(request)")
  case let .response(response):
    print("We received a response: \(response)")
  case let .event(event):
    print("We received an event: \(event)")
  }
}
```

### `case`<a name="case"></a>

The `case` operator focuses on a particular case of an enum of a stream where the Element is `CasePathable` allowing us to subscribe to its associate value.

```swift
let events = try await webSocket
  .receive(id: id)
  .success(of: Message.self)
  .case(\.event)

// event is of type AsyncStream<Event>
for await event in events {
  switch event {
  case let .newUser(user):
    print("We have a new user: \(user)")
  case .streamStarted:
    print("Stream has started")
  case .streamStopped:
    print("Stream has stopped")
  }
}
```

### `field`<a name="field"></a>

The `field` operator focuses on a specific field of a type for a given `keyPath`.

```swift
 let firstUsers = try await webSocket
   .receive(id: id)
   .success(of: Message.self)
   .case(\.response.success.getUsers)
   .field(\.users[0].name)

 // firstUsers is of type AsyncStream<String>
 for await user in firstUsers {
   print("The first user of the list is \(user)")
 }
```

## Getting started

The following is a code that can be copy and paste to try out the library.
Each comment describes each step.
The sample code can be run on any WebSocket endpoint prodived that the URL and port are valid.

The code example assumes there is a WebSocket server running locally with URL `ws://localhost` at port `8888`.

If needed, the examples repo contains servers that can be run locally to test the library.

```swift
import AsyncWebSocket

@main
@MainActor
struct MainApp {
  static func main() async throws {

    /// Default instance of a WebSocket client.
    let webSocket = AsyncWebSocketClient.default

    /// A uniquely identifiable value to use for subsequent requests to the server.
    let id = AsyncWebSocketClient.ID()

    /// Connectivity status subscription
    let connectionStatus  = try await webSocket.open(
      AsyncWebSocketClient.Settings(
        id: id,
        url: "ws://localhost",
        port: 8888
      )
    )

    // Starts listening for connection events.
    for await status in connectionStatus {
      switch status {
      case .connected:
        print("[WebSocket - Status - Connected]: Connected to the server!")
        // At this point a connection with the server has been established.
        // We can start listening for incoming frames or send frames to the server.
        async let listening: Void = startListeningForIncomingFrames()
        async let sending: Void = sendFramesToTheServer()

        try await listening
        try await sending

      case .connecting:
        print("[WebSocket - Status - Connecting]: Connecting...")
      case let .didClose(code):
        print("[WebSocket - Status - Close]: Connection with server did close with the code: \(code)")
      case let .didFail(error):
        print("[WebSocket - Status - Failure]: Connection with server did fail with error: \(error)")
      }
    }

    /// Initiates the act of receiving frames from the server.
    @Sendable
    func startListeningForIncomingFrames() async throws {
      let frames = try await webSocket.receive(id)

      for await frame in frames {
        switch frame {
        case let .message(.binary(data)):
          print("[WebSocket - Frame - Message.binary]: \(data)")
        case let .message(.text(string)):
          print("[WebSocket - Frame - Message.text]: \(string)")
        case let .ping(data):
          print("[WebSocket - Frame - Ping]: \(data)")
        case let .pong(data):
          print("[WebSocket - Frame - Pong]: \(data)")
        case let .close(code):
          print("[WebSocket - Frame - Close]: \(code)")
        }
      }
    }

    /// Sends a series of frames to the server.
    @Sendable
    func sendFramesToTheServer() async throws {
      let data = "Hello".data(using: .utf8)!
      try await webSocket.send(id, .message(.binary(data)))
      try await webSocket.send(id, .message(.text("Hello")))
      try await webSocket.send(id, .ping())
//      try await webSocket.send(id, .close(code: .goingAway))
    }
  }
}
```

Once a connection is established with a WebSocket server we can simply use `for await in` to listen for connection status and subscribe for incomming frames

```swift
/// Default instance of a WebSocket client.
let webSocket = AsyncWebSocketClient.default
/// Generates a uniquely identifiable value to use for subsequent requests to the server.
let id = AsyncWebSocketClient.ID()
/// Connectivity status subscription
let connection = try await webSocket.open(
  AsyncWebSocketClient.Settings(
    id: id,
    url: "ws://enter-a-valid-URL-here", // A valid URL should be entered here
    port: 8888 // A valid port should be entered here
  )
)

for await _ in connection.on(\.connected) {
  let frames = try await webSocket.receive(id)
  for await frame in frames {
    print("Frame received: ", frame)
  }
}
```

But often we want to focus on a particular frame and ignore the rest, in this case we can take advantage of the `on(Frame)` operator.

Let's say we want to only focus on the Message.Text frame, a frame often used to receive json encoded as string, one way to do it with the `on(Frame)` operator is as follow.

```swift
struct User: Codable {
 let name: String
 let id: Int
}

for await _ in connection.on(\.connected) {
  let frames = try await webSocket.receive(id)

  Task {
    // Only receives Message.Text frame and ignore the rest.
    for await json in frames.on(\.message.text) {
      let data = json.data(using: .utf8)!
      // Decodes the json into User Type.
      let user = try JSONDecoder().decode(User.self, from: data)
      print("User: \(user)")
    }
  }
}
```

There are also situations where we want to focus on a particular notification but still be informed in some way of all the events happenning during the communication between the client and the WebSocket server this is where the `log` operator comes into play.

This operator still delivers events but at the same time logs logs them using a custom log behaviour or a default one if none is provided.

In the following example we:

1. Connect to a local  [WebSocket Emojis Server](https://github.com/cham-s/async-websocket-examples/tree/main/Sources/EmojisServer) (a server that communicates with a client via requests here we start the stream to receive a random emoji for every second)

2. Listen for a couple of events

3. Shutdown the server (pressing Ctrl-C)

##### Default logger

If no log operation is provided as argument to the `log` operator a default one will be invoked.

```swift
extension AsyncStream where Element == AsyncWebSocketClient.Frame {
  /// Transforms a stream of Frame into a stream of Emoji Message
  func emojiMessage() throws -> AsyncStream<Message> {
    self
      .log()
      .on(\.message.text)
      .success(of: Message.self)
  }
}
```

<details>

<summary>Shell log session</summary>

```shellsession
2024-11-03T12:10:56+0100 info com.async-webosocket-connection : [AsyncWebSocketOperators] : AsyncWebSocketClient.ConnectionStatus.connecting
2024-11-03T12:10:56+0100 info com.async-webosocket-connection : [AsyncWebSocketOperators] : AsyncWebSocketClient.ConnectionStatus.connected
2024-11-03T12:10:56+0100 info com.async-webosocket-frame : [AsyncWebSocketOperators] : AsyncWebSocketClient.Frame.message(
  .text(
    """
    {
      "welcome" : {
        "_0" : {
          "message" : "Welcome to the Emojis server 😃"
        }
      }
    }
    """
  )
)
Welcome to the Emojis server 😃
2024-11-03T12:10:56+0100 info com.async-webosocket-frame : [AsyncWebSocketOperators] : AsyncWebSocketClient.Frame.message(
  .text(
    """
    {
      "response" : {
        "_0" : {
          "succcess" : {
            "_0" : {
              "startStream" : {

              }
            }
          }
        }
      }
    }
    """

  )
)
Starting stream
2024-11-03T12:10:57+0100 info com.async-webosocket-frame : [AsyncWebSocketOperators] : AsyncWebSocketClient.Frame.message(
  .text(
    """
    {
      "event" : {
        "_0" : {
          "emojiDidChangedEvent" : {
            "_0" : {
              "newEmoji" : "🌺"
            }
          }
        }
      }
    }
    """
  )
)
New emoji:  🌺
2024-11-03T12:10:58+0100 info com.async-webosocket-frame : [AsyncWebSocketOperators] : AsyncWebSocketClient.Frame.message(
  .text(
    """
    {
      "event" : {
        "_0" : {
          "emojiDidChangedEvent" : {
            "_0" : {
              "newEmoji" : "💞"
            }
          }
        }
      }
    }
    """
  )
)
New emoji:  💞
2024-11-03T12:10:58+0100 info com.async-webosocket-frame : [AsyncWebSocketOperators] : AsyncWebSocketClient.Frame.close(code: .unexpectedServerError)
2024-11-03T12:10:58+0100 info com.async-webosocket-connection : [AsyncWebSocketOperators] : AsyncWebSocketClient.ConnectionStatus.didClose(.unexpectedServerError)
```

</details>

##### Custom logger

In this example we go through implementing a custom log operation that will be used in the operator.
Here a formatted output is presented to emphasize each json frame received.

<details>
<summary><code>formatted(title: String, message: String)</code> implementation</summary>

```swift
fileprivate func formatted(
  title: String,
  message: String
) -> String {
  let messageSplit = message.split(separator: "\n")
  let maxCount = messageSplit.map(\.count).max() ?? 0
  let received = " \(title) "
  let count = maxCount / 2

  // String of repeating character
  let `repeat`: (Character, Int) -> String = String.init(repeating:count:)
  let headerContent = "\(`repeat`("⎺", count))\(received)\(`repeat`("⎺", count))"
  let header = "⌈\(headerContent)⌉"
  let footer = "⌊\(`repeat`("⎽", (count * 2) + received.count))⌋"

  let body = messageSplit.reduce(into: [String]()) { result, line in
    let leadingSpaces = `repeat`(" ", 2)
    let lineContent = "\(leadingSpaces)\(line)"
    result.append(lineContent)
  }.joined(separator: "\n")

  return """
  \(header)

  \(body)

  \(footer)
  """
}
```

</details>

```swift
fileprivate let frameLogger = { (frame: AsyncWebSocketClient.Frame) in
  var logger = Logger(label: "Emoji-Server-Client")
  guard let text = frame[case: \.message.text]
  else {
    logger.info("", metadata:["Frame Update":  " \(frame)"])
    return
  }
  logger.info("\n\n\(formatted(title: "Received Text Frame", message: text))\n")
}

extension AsyncStream where Element == AsyncWebSocketClient.Frame {
  /// Transforms a stream of Frame into a stream of Emoji Message
  func emojiMessage() throws -> AsyncStream<Message> {
    self
      .log(action: frameLogger)
      .on(\.message.text)
      .success(of: Message.self)
  }
}
```

<details>
<summary>Log session with formatted log output</summary>

```shellsession
2024-11-03T12:17:04+0100 info com.async-webosocket-connection : [AsyncWebSocketOperators] : AsyncWebSocketClient.ConnectionStatus.connecting
2024-11-03T12:17:04+0100 info com.async-webosocket-connection : [AsyncWebSocketOperators] : AsyncWebSocketClient.ConnectionStatus.connected
2024-11-03T12:17:04+0100 info Emoji-Server-Client : [EmojisDemo] 

⌈⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺ Received Text Frame ⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⌉

  {
    "welcome" : {
      "_0" : {
        "message" : "Welcome to the Emojis server 😃"
      }
    }
  }

⌊⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⌋

Welcome to the Emojis server 😃
2024-11-03T12:17:04+0100 info Emoji-Server-Client : [EmojisDemo] 

⌈⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺ Received Text Frame ⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⌉

  {
    "response" : {
      "_0" : {
        "succcess" : {
          "_0" : {
            "startStream" : {
            }
          }
        }
      }
    }
  }

⌊⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⌋

Starting stream
2024-11-03T12:17:05+0100 info Emoji-Server-Client : [EmojisDemo] 

⌈⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺ Received Text Frame ⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⌉

  {
    "event" : {
      "_0" : {
        "emojiDidChangedEvent" : {
          "_0" : {
            "newEmoji" : "🍅"
          }
        }
      }
    }
  }

⌊⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⌋

New emoji:  🍅
2024-11-03T12:17:06+0100 info Emoji-Server-Client : [EmojisDemo] 

⌈⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺ Received Text Frame ⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⌉

  {
    "event" : {
      "_0" : {
        "emojiDidChangedEvent" : {
          "_0" : {
            "newEmoji" : "🎑"
          }
        }
      }
    }
  }

⌊⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⌋

New emoji:  🎑
2024-11-03T12:17:07+0100 info Emoji-Server-Client : [EmojisDemo] 

⌈⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺ Received Text Frame ⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⌉

  {
    "event" : {
      "_0" : {
        "emojiDidChangedEvent" : {
          "_0" : {
            "newEmoji" : "💠"
          }
        }
      }
    }
  }

⌊⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⌋

New emoji:  💠
2024-11-03T12:17:08+0100 info Emoji-Server-Client : [EmojisDemo] 

⌈⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺ Received Text Frame ⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⌉

  {
    "event" : {
      "_0" : {
        "emojiDidChangedEvent" : {
          "_0" : {
            "newEmoji" : "💘"
          }
        }
      }
    }
  }

⌊⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⌋

New emoji:  💘
2024-11-03T12:17:09+0100 info Emoji-Server-Client : [EmojisDemo] 

⌈⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺ Received Text Frame ⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⎺⌉

  {
    "event" : {
      "_0" : {
        "emojiDidChangedEvent" : {
          "_0" : {
            "newEmoji" : "🍹"
          }
        }
      }
    }
  }

⌊⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⎽⌋

New emoji:  🍹
2024-11-03T12:17:10+0100 info Emoji-Server-Client : Frame Update= close(code: NIOWebSocket.WebSocketErrorCode.unexpectedServerError) [EmojisDemo] 
2024-11-03T12:17:10+0100 info com.async-webosocket-connection : [AsyncWebSocketOperators] : AsyncWebSocketClient.ConnectionStatus.didClose(.unexpectedServerError)
```

</details>

## More examples

There is a dedicaded package with example demos that demonstrates different uses of the library: [examples-package](https://github.com/cham-s/async-websocket-examples)

## Things to be aware of <a name="aware-of"></a>

- [WebSocket frames subset](#subset)

- [Import the necessary](#import)

- [Swift Macros](#macros)

#### WebSocket frames subset <a name="subset"></a>

For simplicity the client only supports the most use frames to be sent or received.

- message.data, a collection of bytes
- message.text, an encoded string
- ping, to check if the connection with the other endpoint is still alive
- pong, to respond to a ping
- close, to close the connection with the other endpoint

#### Import the necessary <a name="import"></a>

For modularity the package contains four targets it is important to select only what is needed for a given situation.

###### AsyncWebSocket

```swift
import AsyncWebSocket
```

<h5>Imported modules</h5>

```swift
import AsyncWebSocketClient
import AsyncWebSocketClientLive
import AsyncWebSocketOperators
import Dependencies
import NIOCore
import NIOPosix
import WebSocketKit
```

This target is an umbrella target that import all targets it is for people who find selecting the right library confusing or just want to quickly test the library without guessing what library contains what feature.

In this situation unessary code might be imported.

###### AsyncWebSocketClient

```swift
import AsyncWebSocketClient
```

This target is very light it contains only interface code and types used throughout the library.

It can be used in situations where only types and symbols are needed without any heavy implementation code that can have other heavy libraries.

###### AsyncWebSocketClientLive

```swift
import AsyncWebSocketClientLive
```

This target is more heavy weighted it contains the default implementation of the client it depdends on external libraries such as swift-nio or websocket-kit to perform its logic.

###### AsyncWebSocketOperators

```swift
import AsyncWebSocketOperators
```

This target contains code for additional functionalities to improve the use of the library.



The goal is to compose with the right set of module needed for a given situation.

#### Swift Macros<a name="macros"></a>

The package itself doesn't use Swift Macros but depends on packages that take advantage of this powerful feature, so XCode might ask you to enable the feature for packages that use it.

## Credits and inspirations <a name="credits"></a>

The original idea comes from a [case study](https://github.com/pointfreeco/swift-composable-architecture/blob/main/Examples/CaseStudies/SwiftUICaseStudies/03-Effects-WebSocket.swift) that demonstrates the use of a dependency such as WebSocket in The Composable Architecture.

The original implementation uses Foundation for the WebSocket protocol logic.The current implementation is different but mainly due to some limitations of Foundation when it comes to WebSocket I decided to implement the library using websocket-kit and swift-nio.

I also added operators to focus on particular event and the log operator, this is possible thanks to CaseKeyPath.

Credits:

- Apple: [swift-nio](https://github.com/apple/swift-nio), [swift-log](https://github.com/apple/swift-log)

- Point-Free: [case-paths](https://github.com/pointfreeco/swift-case-paths), [dependencies](https://github.com/pointfreeco/swift-dependencies), [custom-dump](https://github.com/pointfreeco/swift-custom-dump), [tagged](https://github.com/pointfreeco/swift-tagged)

- Vapor: [websocket-kit](https://github.com/vapor/websocket-kit)

## Feedbacks <a name="feedback"></a>

As mentioned above the package is experimental, any kind of feedback or review (code, english grammar) are welcomed.
