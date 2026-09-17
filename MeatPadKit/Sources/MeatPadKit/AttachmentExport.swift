import Foundation

/// File names for attachments leaving the app (drag-out). The stored file is `<uuid>.<ext>`;
/// the outside world gets the card title instead.
public enum AttachmentExport {
    public static func fileName(title: String, index: Int, ext: String, fallback: String) -> String {
        var base = title.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.newlines))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        base = String(base.drop { $0 == "." }.prefix(120))
        if base.isEmpty { base = fallback }
        let numbered = index == 0 ? base : "\(base) \(index + 1)"
        return ext.isEmpty ? numbered : "\(numbered).\(ext)"
    }
}
