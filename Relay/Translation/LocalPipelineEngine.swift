import Foundation
import AVFoundation

/// The two-hop pipeline: recognise speech on this Mac, then send the text to a
/// text model for translation.
///
/// Both halves are injected, so this one class covers every combination of
/// Whisper/Apple recognition and Claude/OpenAI translation. Only the OpenAI
/// Realtime provider bypasses it, because that model takes audio directly.
final class LocalPipelineEngine: TranslationEngine {

    var onStateChange: ((EngineState) -> Void)?
    var onPartialTranslation: ((String, Int?) -> Void)?
    var onFinalTranslation: ((String, Int?) -> Void)?
    var onFatalError: ((String) -> Void)?

    private let transcriber: SpeechTranscribing
    private let translator: TextTranslating
    private var startTask: Task<Void, Never>?

    /// Speakers wait here between recognition and translation. The translator
    /// handles one utterance at a time in order, so a queue keeps each label
    /// with the line it came from.
    private var pendingSpeakers: [Int?] = []

    init(transcriber: SpeechTranscribing, translator: TextTranslating) {
        self.transcriber = transcriber
        self.translator = translator
    }

    func start(source: SourceLanguageSetting, target: Language) throws {
        translator.onPartial = { [weak self] text in
            self?.onPartialTranslation?(text, self?.pendingSpeakers.first ?? nil)
        }
        translator.onFinal = { [weak self] text in
            guard let self else { return }
            let speaker = self.pendingSpeakers.isEmpty ? nil : self.pendingSpeakers.removeFirst()
            self.onFinalTranslation?(text, speaker)
        }
        translator.onFatalError = { [weak self] message in self?.onFatalError?(message) }

        transcriber.onFinalText = { [weak self] result in
            guard let self else { return }
            self.pendingSpeakers.append(result.speaker)
            self.translator.translate(result.text)
        }
        transcriber.onError = { [weak self] error in
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            self?.onFatalError?(message)
        }

        emit(.connecting)

        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                // May download a speech model on first use, so the UI stays on
                // "Starting…" until this lands.
                try await self.transcriber.start(language: source.language)
                self.emit(.ready)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { self.onFatalError?(message) }
            }
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        transcriber.receive(buffer)
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        pendingSpeakers.removeAll()
        translator.cancel()

        let transcriber = self.transcriber
        Task { await transcriber.stop() }
        emit(.idle)
    }

    private func emit(_ state: EngineState) {
        if Thread.isMainThread {
            onStateChange?(state)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
        }
    }
}
