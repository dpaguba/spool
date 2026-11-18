import CryptoKit
import Foundation

/// Helpers for logins kept as generic Keychain passwords.
enum KeychainOutput {
    /// Parses what `security find-generic-password -w` prints: the payload with a trailing
    /// newline, or the same bytes as hex digits, which `security` may print for a password it
    /// does not treat as plain text. The trimmed payload is tried first.
    static func parse<T>(_ data: Data, with parse: (Data) throws -> T) throws -> T {
        var bytes = [UInt8](data)
        while let last = bytes.last, last == 0x0A || last == 0x0D || last == 0x20 || last == 0x09 {
            bytes.removeLast()
        }
        do {
            return try parse(Data(bytes))
        } catch {
            guard let decoded = hexDecoded(bytes) else { throw error }
            return try parse(decoded)
        }
    }

    /// Lowercase hex digits of the SHA-256 of `text` as UTF-8.
    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func hexDecoded(_ bytes: [UInt8]) -> Data? {
        guard !bytes.isEmpty, bytes.count.isMultiple(of: 2) else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x37
            case 0x61...0x66: byte - 0x57
            default: nil
            }
        }
        var result = Data(capacity: bytes.count / 2)
        for index in stride(from: 0, to: bytes.count, by: 2) {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            result.append(high << 4 | low)
        }
        return result
    }
}
