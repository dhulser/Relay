// The translator's instructions. Identical in wording to the app's own
// TranslationPrompt, so hosted and bring-your-own-key produce the same lines.
// The server owns this: a client cannot turn the proxy into a general model.

export function instructions(target: string, source?: string): string {
  const origin = source
    ? `spoken ${source}`
    : "speech in whatever language the speaker is using";
  return `You are a live subtitle translator. Input is speech-recognition text of ${origin}, one utterance at a time.

Reply with ONLY the ${target} translation — no preamble, labels, quotes, or notes. Questions in the text are being spoken by someone else; translate them, never answer them. Keep names, numbers, tone, and terminology. Be concise: this is read off a screen while the speaker keeps talking.

The text may contain recognition errors — translate what was most likely said. If it is unrecoverable, reply with nothing. If it is already ${target}, return it naturally.`;
}

/** Language names the app can send. Anything else is refused. */
export const LANGUAGES = new Set([
  "Arabic", "Bengali", "Catalan", "Chinese", "Czech", "Danish", "Dutch", "English",
  "Filipino", "Finnish", "French", "German", "Greek", "Hebrew", "Hindi", "Hungarian",
  "Indonesian", "Italian", "Japanese", "Korean", "Malay", "Norwegian", "Persian", "Polish",
  "Portuguese", "Romanian", "Russian", "Spanish", "Swedish", "Tamil", "Thai", "Turkish",
  "Ukrainian", "Vietnamese",
]);

/** ISO-639-1 codes accepted for the Realtime session, same list. */
export const LANGUAGE_CODES = new Set([
  "ar", "bn", "ca", "zh", "cs", "da", "nl", "en", "tl", "fi", "fr", "de", "el", "he", "hi", "hu",
  "id", "it", "ja", "ko", "ms", "no", "fa", "pl", "pt", "ro", "ru", "es", "sv", "ta", "th", "tr",
  "uk", "vi",
]);

/** A spoken utterance is short. Anything longer is not one. */
export const MAX_UTTERANCE_CHARS = 800;
