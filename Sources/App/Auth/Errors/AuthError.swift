import Hummingbird

enum AuthError {
    static let invalidCredentials = HTTPError(.unauthorized, message: "invalid credentials")
    static let accountLocked = HTTPError(.init(code: 423), message: "account locked")
    static let emailExists = HTTPError(.conflict, message: "email already registered")
    static let usernameTaken = HTTPError(.conflict, message: "username already taken")
    static let invalidUsername = HTTPError(.badRequest, message: "username must be 3-31 chars, lowercase a-z/0-9/-, not reserved")
    static let weakPassword = HTTPError(.badRequest, message: "password too short (min 12)")
    static let mfaRequired = HTTPError(.unauthorized, message: "mfa required")
    static let mfaInvalid = HTTPError(.unauthorized, message: "mfa code invalid")
    static let invalidRefresh = HTTPError(.unauthorized, message: "invalid refresh token")
    static let resetCodeInvalid = HTTPError(.unauthorized, message: "reset code invalid or expired")
    static let resetLocked = HTTPError(.tooManyRequests, message: "reset locked, try later")
}
