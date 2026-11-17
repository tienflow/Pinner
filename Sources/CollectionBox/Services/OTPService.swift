import Foundation
import CommonCrypto

public enum OTPService {
    private static let base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    /// Decode a base32 string to Data.
    public static func base32Decode(_ input: String) -> Data? {
        let cleaned = input
            .uppercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "=", with: "")
        guard !cleaned.isEmpty else { return nil }

        var bits = ""
        for char in cleaned {
            guard let idx = base32Alphabet.firstIndex(of: char) else { return nil }
            let val = base32Alphabet.distance(from: base32Alphabet.startIndex, to: idx)
            let binary = String(val, radix: 2)
            bits += String(repeating: "0", count: 5 - binary.count) + binary
        }

        var data = Data()
        var i = bits.startIndex
        while i < bits.endIndex {
            let end = bits.index(i, offsetBy: 8, limitedBy: bits.endIndex) ?? bits.endIndex
            let slice = String(bits[i..<end])
            guard slice.count == 8, let byte = UInt8(slice, radix: 2) else { break }
            data.append(byte)
            i = end
        }
        return data.isEmpty ? nil : data
    }

    /// Generate a TOTP code for the given secret at the specified time.
    ///
    /// Defaults are the RFC 6238 baseline (HMAC-SHA1 / 30 s / 6 digits); the
    /// per-account parameters let SHA256/SHA512 and 8-digit issuers work too.
    public static func generateCode(
        secret: String,
        algorithm: OTPAlgorithm = .sha1,
        digits: Int = 6,
        period: Int = 30,
        at date: Date = Date()
    ) -> String? {
        guard let keyData = base32Decode(secret) else { return nil }
        let step = max(1, period)
        let codeDigits = (6...8).contains(digits) ? digits : 6

        let counter = UInt64(max(0, date.timeIntervalSince1970)) / UInt64(step)
        var counterBig = counter.bigEndian
        let counterData = Data(bytes: &counterBig, count: 8)

        let digestLength: Int
        let hmacAlgorithm: CCHmacAlgorithm
        switch algorithm {
        case .sha1:
            digestLength = Int(CC_SHA1_DIGEST_LENGTH)
            hmacAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA1)
        case .sha256:
            digestLength = Int(CC_SHA256_DIGEST_LENGTH)
            hmacAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA256)
        case .sha512:
            digestLength = Int(CC_SHA512_DIGEST_LENGTH)
            hmacAlgorithm = CCHmacAlgorithm(kCCHmacAlgSHA512)
        }

        var mac = [UInt8](repeating: 0, count: digestLength)
        counterData.withUnsafeBytes { cBytes in
            keyData.withUnsafeBytes { kBytes in
                CCHmac(hmacAlgorithm,
                       kBytes.baseAddress, keyData.count,
                       cBytes.baseAddress, counterData.count,
                       &mac)
            }
        }

        // Dynamic truncation is identical for every digest size (RFC 4226 §5.3),
        // and the offset is keyed off the *last* byte of whichever digest we used.
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = ((UInt32(mac[offset]) & 0x7F) << 24)
                   | ((UInt32(mac[offset + 1]) & 0xFF) << 16)
                   | ((UInt32(mac[offset + 2]) & 0xFF) << 8)
                   | (UInt32(mac[offset + 3]) & 0xFF)

        let modulus: UInt32 = codeDigits == 8 ? 100_000_000 : (codeDigits == 7 ? 10_000_000 : 1_000_000)
        let value = binary % modulus
        return String(format: "%0\(codeDigits)d", value)
    }

    /// Seconds remaining in the current TOTP window.
    public static func timeRemaining(period: Int = 30, at date: Date = Date()) -> Int {
        let step = max(1, period)
        let t = Int(date.timeIntervalSince1970)
        let rem = step - ((t % step + step) % step)
        return rem == 0 ? step : rem
    }

    /// Validate that a string is valid base32.
    public static func isValidBase32(_ input: String) -> Bool {
        base32Decode(input) != nil
    }

    /// Parsed result from an otpauth:// URI.
    public struct OTPAuthInfo {
        public let name: String
        public let secret: String
        public let issuer: String
        public let algorithm: OTPAlgorithm
        public let digits: Int
        public let period: Int

        public init(
            name: String,
            secret: String,
            issuer: String,
            algorithm: OTPAlgorithm = .sha1,
            digits: Int = 6,
            period: Int = 30
        ) {
            self.name = name
            self.secret = secret
            self.issuer = issuer
            self.algorithm = algorithm
            self.digits = digits
            self.period = period
        }
    }

    /// Parse an otpauth://totp/... URI.
    public static func parseOTPAuthURI(_ uri: String) -> OTPAuthInfo? {
        guard uri.hasPrefix("otpauth://totp/") else { return nil }
        let rest = String(uri.dropFirst("otpauth://totp/".count))

        // Split label from query
        guard let qIndex = rest.firstIndex(of: "?") else { return nil }
        let label = String(rest[rest.startIndex..<qIndex]).removingPercentEncoding ?? ""
        let queryString = String(rest[rest.index(after: qIndex)...])

        // Parse query params
        var params = [String: String]()
        for pair in queryString.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 {
                params[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
            }
        }

        guard let secret = params["secret"], !secret.isEmpty, isValidBase32(secret) else { return nil }
        let issuer = params["issuer"] ?? ""
        let name = label

        // Google Authenticator / 1Password style extensions. Unknown or malformed
        // values fall back to the RFC baseline rather than rejecting the URI.
        let algorithm = OTPAlgorithm(rawValue: (params["algorithm"] ?? "").uppercased()) ?? .sha1
        let digits = Int(params["digits"] ?? "") ?? 6
        let period = Int(params["period"] ?? "") ?? 30

        return OTPAuthInfo(
            name: name,
            secret: secret,
            issuer: issuer,
            algorithm: algorithm,
            digits: (6...8).contains(digits) ? digits : 6,
            period: period > 0 ? period : 30
        )
    }
}
