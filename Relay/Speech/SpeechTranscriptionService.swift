import Foundation
import AVFoundation
import Speech

/// On-device speech recognition using macOS 26's `SpeechAnalyzer`.
///
/// This is the first half of the Claude pipeline: Claude has no audio input, so
/// speech becomes text here — locally, at no cost, without the audio leaving
/// the machine — and only the text is sent to the API.
///
/// The `.progressiveTranscription` preset emits *volatile* results that get
/// revised as the speaker continues, then a *final* result once the utterance
/// settles. That maps directly onto partial vs. finished subtitles.
@available(macOS 26.0, *)
final class SpeechTranscriptionService: SpeechTranscribing {

    /// A settled utterance. This text will not change again.
    var onFinalText: ((TranscriptionResult) -> Void)?

    var onError: ((Error) -> Void)?

    /// Best guess at what's being said right now. Not part of the protocol —
    /// nothing consumes it yet, but the recogniser produces it for free.
    var onVolatileText: ((String) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AudioConverter?
    private var reservedLocale: Locale?

    private var buffersAccepted = 0

    /// Prepares the recogniser for `language`, downloading its model if macOS
    /// doesn't have it yet. Must complete before `receive(_:)` is called.
    func start(language: Language?) async throws {
        guard let language else {
            // Guaranteed by the picker, which hides Auto-detect for this
            // engine — but never silently pick a language behind the user.
            throw EngineError.unsupportedLanguage(
                "Apple's recogniser can't detect the language. Choose a specific source "
                + "language, or switch the speech engine to Whisper."
            )
        }
        guard SpeechTranscriber.isAvailable else {
            throw EngineError.setupFailed("Speech recognition is unavailable on this Mac.")
        }

        let requested = Locale(identifier: language.isoCode)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            let supported = await SpeechTranscriber.supportedLocales
                .compactMap { $0.language.languageCode?.identifier }
            throw EngineError.unsupportedLanguage(
                "macOS speech recognition doesn't support \(language.displayName). "
                + "Supported: \(Set(supported).sorted().joined(separator: ", ")). "
                + "Switch the source language, or use the OpenAI provider."
            )
        }

        // .fastResults biases the recogniser towards responsiveness so results
        // stream while the speaker is still talking, rather than only at pauses.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        // The language model is a separate download managed by the system.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            Log.info(.speech, "Downloading \(locale.identifier) speech model…")
            try await request.downloadAndInstall()
            Log.info(.speech, "Speech model installed")
        }

        // Reserving keeps macOS from evicting the model mid-session.
        if let reserved = try? await AssetInventory.reserve(locale: locale), reserved {
            reservedLocale = locale
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.setupFailed("No compatible audio format for speech recognition.")
        }
        converter = AudioConverter(target: analyzerFormat)
        Log.info(.speech, "Analyzer format: \(AudioConverter.describe(analyzerFormat))")

        // Bounded, newest-wins: live audio must not grow an unbounded queue if
        // the analyzer stalls — dropping stale buffers beats leaking memory.
        let (stream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        self.continuation = continuation

        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .high, modelRetention: .lingering)
        )
        self.analyzer = analyzer

        // Warms the model so the first utterance isn't slower than the rest.
        try await analyzer.prepareToAnalyze(in: analyzerFormat)

        // Consume results before starting, so nothing is missed.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    if result.isFinal {
                        Log.content(.speech, text)
                        let output = TranscriptionResult(text: text, languageCode: language.isoCode)
                        await MainActor.run { self.onFinalText?(output) }
                    } else {
                        await MainActor.run { self.onVolatileText?(text) }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                Log.error(.speech, "Recognition failed: \(error.localizedDescription)")
                await MainActor.run { [weak self] in self?.onError?(error) }
            }
        }

        try await analyzer.start(inputSequence: stream)
        buffersAccepted = 0
        Log.info(.speech, "Transcribing \(language.displayName) (\(locale.identifier))")
    }

    /// Called on the audio capture queue.
    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let continuation,
              let converted = converter.convert(buffer) else { return }

        buffersAccepted += 1
        if buffersAccepted == 1 { Log.info(.speech, "Receiving audio") }

        continuation.yield(AnalyzerInput(buffer: converted))
    }

    func stop() async {
        continuation?.finish()
        continuation = nil

        if let analyzer {
            // Flush whatever is still buffered so the last utterance lands.
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil

        resultsTask?.cancel()
        resultsTask = nil
        transcriber = nil
        converter = nil

        if let reservedLocale {
            await AssetInventory.release(reservedLocale: reservedLocale)
            self.reservedLocale = nil
        }
        Log.info(.speech, "Transcription stopped")
    }
}
