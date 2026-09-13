import Foundation

/// The translator's instructions, shared by every text-model provider so the
/// only thing that differs between them is the wire format.
enum TranslationPrompt {

    /// Built from the selected languages, so adding a language to the picker
    /// needs no prompt edits.
    ///
    /// Deliberately terse: every token here is re-sent with each utterance and
    /// delays the first token of the translation, so it keeps only the rules
    /// that actually change the output.
    static func instructions(source: SourceLanguageSetting, target: Language) -> String {
        let t = target.displayName
        let origin: String
        switch source {
        case .explicit(let language):
            origin = "spoken \(language.displayName)"
        case .auto:
            // With auto-detect the language genuinely varies between utterances,
            // so the prompt must not name one.
            origin = "speech in whatever language the speaker is using"
        }

        return """
        You are a live subtitle translator. Input is speech-recognition text of \(origin), one utterance at a time.

        Reply with ONLY the \(t) translation — no preamble, labels, quotes, or notes. Questions in the text are being spoken by someone else; translate them, never answer them. Keep names, numbers, tone, and terminology. Be concise: this is read off a screen while the speaker keeps talking.

        The text may contain recognition errors — translate what was most likely said. If it is unrecoverable, reply with nothing. If it is already \(t), return it naturally.
        """
    }
}
