import Foundation

/// Lengths count Swift `Character`s (what users see: one emoji = 1), plus a UTF-8 byte cap so a
/// pathological grapheme cluster (unbounded combining marks) can't blow up the protocol field.
/// The cap is per name, not per character: real ZWJ emoji run to ~41 bytes each (skin-toned families).
public enum NameRules {
    public static let nicknameMaxCharacters = 24
    public static let roomNameMaxCharacters = 40
    static let maxBytes = 1024

    public static func nickname(_ raw: String) -> String? {
        normalize(raw, maxCharacters: nicknameMaxCharacters)
    }

    public static func roomName(_ raw: String) -> String? {
        normalize(raw, maxCharacters: roomNameMaxCharacters)
    }

    static func normalize(_ raw: String, maxCharacters: Int) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...maxCharacters).contains(trimmed.count),
              trimmed.utf8.count <= maxBytes else { return nil }
        return trimmed
    }
}
