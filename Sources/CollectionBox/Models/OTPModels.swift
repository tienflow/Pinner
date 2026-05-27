import Foundation

public struct OTPAccount: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var secret: String
    public var issuer: String

    public init(id: UUID = UUID(), name: String, secret: String, issuer: String = "") {
        self.id = id
        self.name = name
        self.secret = secret
        self.issuer = issuer
    }
}
