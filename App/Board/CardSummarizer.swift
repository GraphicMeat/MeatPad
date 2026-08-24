import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device model, used for exactly one thing: turning a card's notes into a title.
///
/// Everything here is conditional on purpose. The framework is macOS 26 only (MeatPad ships
/// back to 14), the model is a download the user may not have, and it speaks the Apple
/// Intelligence languages only — Lithuanian, among many others, is not one of them and the
/// framework throws `unsupportedLanguageOrLocale` rather than guessing. So the menu item is
/// absent unless the model can genuinely handle *this* card's text, instead of offering a
/// button that fails.
enum CardSummarizer {

    /// Below this a title is already what you have; asking a model to shorten it is theatre.
    private static let minimumLength = 200

    /// The model's context is small; a long note is summarized from its opening, which is
    /// where a pasted item states its point anyway.
    private static let promptLimit = 4_000

    static func canSummarize(_ text: String) -> Bool {
        guard text.count >= minimumLength else { return false }
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { return false }
        guard case .available = SystemLanguageModel.default.availability else { return false }
        guard let language = NLLanguageRecognizer.dominantLanguage(for: text) else { return false }
        // Match on the language code alone: the model advertises regional variants
        // (pt-BR, zh-Hans) that a detected "pt"/"zh" would never compare equal to.
        return SystemLanguageModel.default.supportedLanguages.contains {
            $0.languageCode?.identifier == language.rawValue
        }
        #else
        return false
        #endif
    }

    /// nil whenever the model is unavailable, unsupported for this text, or refuses — every
    /// one of which leaves the card exactly as it was.
    static func title(for text: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *), canSummarize(text) else { return nil }
        let session = LanguageModelSession(instructions: """
            You write short task titles. Reply with the title only: no quotes, no trailing \
            period, at most eight words, in the same language as the text you are given.
            """)
        guard let response = try? await session.respond(to: "Write a task title for this note:\n\n\(String(text.prefix(promptLimit)))")
        else { return nil }
        return cleaned(response.content)
        #else
        return nil
        #endif
    }

    /// Models like to answer in quotes and to end a title with a period; a title does neither.
    private static func cleaned(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = text.firstIndex(of: "\n") { text = String(text[..<newline]) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”„‘’ "))
        while let last = text.last, last == "." { text.removeLast() }
        return text
    }
}
