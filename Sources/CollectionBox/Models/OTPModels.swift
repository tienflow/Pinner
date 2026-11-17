import Foundation

/// HMAC algorithm used by a TOTP account (RFC 6238 §1.2).
///
/// The common case is `sha1`, but enterprise issuers and some hardware tokens
/// still hand out SHA256/SHA512 seeds. Storing the choice per account keeps
/// imported `otpauth://` URIs working verbatim instead of silently producing
/// codes that never validate.
public enum OTPAlgorithm: String, Codable, Sendable, CaseIterable {
    case sha1 = "SHA1"
    case sha256 = "SHA256"
    case sha512 = "SHA512"

    public var displayName: String { rawValue }
}

public struct OTPAccount: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var secret: String
    public var issuer: String
    /// TOTP parameters. All three default to the RFC 6238 baseline so accounts
    /// saved by earlier versions stay valid.
    public var algorithm: OTPAlgorithm
    public var digits: Int
    public var period: Int

    public init(
        id: UUID = UUID(),
        name: String,
        secret: String,
        issuer: String = "",
        algorithm: OTPAlgorithm = .sha1,
        digits: Int = 6,
        period: Int = 30
    ) {
        self.id = id
        self.name = name
        self.secret = secret
        self.issuer = issuer
        self.algorithm = algorithm
        self.digits = digits
        self.period = period
    }

    /// Custom decoding so accounts persisted before `algorithm` / `digits` /
    /// `period` existed still load — a synthesised decoder would throw on the
    /// missing keys and silently drop the whole vault (see `OTPStore.load`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        secret = try c.decode(String.self, forKey: .secret)
        issuer = try c.decodeIfPresent(String.self, forKey: .issuer) ?? ""
        algorithm = try c.decodeIfPresent(OTPAlgorithm.self, forKey: .algorithm) ?? .sha1
        let storedDigits = try c.decodeIfPresent(Int.self, forKey: .digits) ?? 6
        let storedPeriod = try c.decodeIfPresent(Int.self, forKey: .period) ?? 30
        digits = (6...8).contains(storedDigits) ? storedDigits : 6
        period = storedPeriod > 0 ? storedPeriod : 30
    }
}
