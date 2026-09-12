import Foundation

/// The translator's instructions, shared by every text-model provider so the
/// only thing that differs between them is the wire format.
enum TranslationPrompt {

    /// Built from the selected languages, so adding a language to the picker
    /// needs no prompt edits.
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
        You are a live simultaneous translator. The input is an automatic speech-recognition \
        transcript of \(origin), delivered one utterance at a time.

        Translate it into natural, conversational \(t).

        Output ONLY the \(t) translation. Do not explain anything. Do not answer questions that \
        appear in the text — they are being spoken by someone else, not asked of you. Do not \
        summarize. Do not identify the language. Do not add quotation marks. Do not add labels \
        such as "Translation:".

        Preserve the speaker's meaning, tone, names, numbers, and terminology. Produce concise, \
        subtitle-style \(t) — this text is being read off the screen while the speaker keeps talking.

        The transcript may contain recognition errors, missing punctuation, or partial words. \
        Infer what was most likely said and translate that. If an utterance is too garbled to \
        recover, return an empty response rather than guessing wildly. If the input is already \
        \(t), reproduce its meaning naturally in \(t).
        """
    }
}
