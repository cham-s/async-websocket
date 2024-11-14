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
  case getUsers(count: Count)
  case startStream
  case stopStream
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

enum Event: Codable, Sendable, Equatable {
  case newUser(NewUserEvent)
}

enum ErrorCode: Codable, Sendable, Equatable {
  case invalidJSONFormat
  case internalServerError
}

enum Message: Codable, Sendable, Equatable {
  case request(Request)
  case response(Response.Result)
  case event(Event)
}
