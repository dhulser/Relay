import Foundation
import Combine

/// Tracks which Whisper models are on disk and downloads the ones that aren't.
///
/// Models live in Application Support rather than the bundle — they're 142 MB
/// to 1.5 GB, and which one you want is a preference, not a build artifact.
@MainActor
final class WhisperModelStore: ObservableObject {
    static let shared = WhisperModelStore()

    @Published private(set) var installed: Set<WhisperModel> = []
    @Published private(set) var downloading: WhisperModel?
    @Published private(set) var progress: Double = 0
    @Published var lastError: String?

    private var task: Task<Void, Never>?

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LiveTranslator/Models", isDirectory: true)
    }()

    private init() { refresh() }

    func url(for model: WhisperModel) -> URL {
        Self.directory.appendingPathComponent(model.fileName)
    }

    func isInstalled(_ model: WhisperModel) -> Bool { installed.contains(model) }

    func refresh() {
        installed = Set(WhisperModel.allCases.filter { model in
            let path = url(for: model).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64 else { return false }
            // A partial file from an interrupted download would otherwise look
            // installed and then fail to load.
            return size > model.approximateBytes / 2
        })
    }

    func download(_ model: WhisperModel) {
        guard downloading == nil else { return }
        downloading = model
        progress = 0
        lastError = nil

        task = Task {
            do {
                try await performDownload(model)
                Log.info(.whisper, "\(model.displayName) model installed")
            } catch is CancellationError {
                Log.info(.whisper, "Download cancelled")
            } catch {
                lastError = error.localizedDescription
                Log.error(.whisper, "Download failed: \(error.localizedDescription)")
            }
            downloading = nil
            progress = 0
            refresh()
        }
    }

    func cancelDownload() {
        task?.cancel()
        task = nil
    }

    func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: url(for: model))
        Log.info(.whisper, "\(model.displayName) model removed")
        refresh()
    }

    private func performDownload(_ model: WhisperModel) async throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        let destination = url(for: model)
        let partial = destination.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        Log.info(.whisper, "Downloading \(model.displayName) model…")
        let (bytes, response) = try await URLSession.shared.bytes(from: model.downloadURL)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "WhisperModelStore", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))",
            ])
        }

        let expected = response.expectedContentLength > 0
            ? response.expectedContentLength
            : model.approximateBytes

        // Buffer writes; a byte-at-a-time FileHandle write on a 1.5 GB model
        // would be pathologically slow.
        var buffer = Data(capacity: 1 << 20)
        var written: Int64 = 0
        var lastReported = Date.distantPast

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                handle.write(buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if Date().timeIntervalSince(lastReported) > 0.2 {
                    lastReported = Date()
                    progress = min(Double(written) / Double(expected), 1)
                }
            }
        }
        if !buffer.isEmpty {
            handle.write(buffer)
            written += Int64(buffer.count)
        }
        try handle.close()

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
        progress = 1
    }
}
