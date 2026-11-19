import Foundation

/// The per-install secret that tells the Finder extension's `meatpad://new-file` requests
/// apart from anyone else's. The app creates it once and keeps it in its own defaults under
/// `defaultsKey`; the extension reads it from there and adds it to each URL.
public enum FinderToken {
    public static let defaultsKey = "finder.token"
    public static let minimumLength = 32

    /// 64 lowercase hex characters from 32 random bytes.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        var text = ""
        text.reserveCapacity(64)
        for _ in 0..<32 {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return text
    }

    /// Non-nil, at least `minimumLength` characters, hex digits only (either case).
    public static func isUsable(_ token: String?) -> Bool {
        guard let token, token.count >= minimumLength else { return false }
        return token.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "0"..."9", "a"..."f", "A"..."F": true
            default: false
            }
        }
    }
}
