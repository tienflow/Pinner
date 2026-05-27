import Foundation
import CommonCrypto

public enum OTPService {
    private static let base32Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

    /// Decode a base32 string to Data.
    public static func base32Decode(_ input: String) -> Data? {
        let cleaned = input.uppercased().replacingOccurrences(of: " ", with: "")
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
        return data
    }

    /// Generate a TOTP code for the given secret at the specified time.
    /// HMAC-SHA1, 30-second time step, 6-digit output (RFC 6238).
    public static func generateCode(secret: String, at date: Date = Date()) -> String? {
        guard let keyData = base32Decode(secret) else { return nil }

        let counter = UInt64(date.timeIntervalSince1970) / 30
        var counterBig = counter.bigEndian
        let counterData = Data(bytes: &counterBig, count: 8)

        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        counterData.withUnsafeBytes { cBytes in
            keyData.withUnsafeBytes { kBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                       kBytes.baseAddress, keyData.count,
                       cBytes.baseAddress, counterData.count,
                       &mac)
            }
        }

        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary = ((UInt32(mac[offset]) & 0x7F) << 24)
                   | ((UInt32(mac[offset + 1]) & 0xFF) << 16)
                   | ((UInt32(mac[offset + 2]) & 0xFF) << 8)
                   | (UInt32(mac[offset + 3]) & 0xFF)

        return String(format: "%06d", binary % 1_000_000)
    }

    /// Seconds remaining in the current 30-second TOTP window.
    public static func timeRemaining(at date: Date = Date()) -> Int {
        Int(date.timeIntervalSince1970) % 30
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

        guard let secret = params["secret"], !secret.isEmpty else { return nil }
        let issuer = params["issuer"] ?? ""
        let name = label

        return OTPAuthInfo(name: name, secret: secret, issuer: issuer)
    }
}
