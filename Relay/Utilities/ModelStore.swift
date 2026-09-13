import Foundation
import Combine

/// A model that can be fetched on demand into Application Support.
protocol DownloadableModel: Identifiable, Hashable, CaseIterable {
    var displayName: String { get }
    var fileName: String { get }
    var downloadURL: URL { get }
    var approximateBytes: Int64 { get }
}

/// Tracks which models are on disk and downloads the ones that aren't.
///
/// Models live in Application Support rather than the bundle — they are tens to
/// hundreds of megabytes, and which one you want is a preference, not a build
/// artifact.
@MainActor
final class ModelStore<Model: DownloadableModel>: ObservableObject {

    @Published private(set) var installed: Set<Model> = []
    @Published private(set) var downloading: Model?
    @Published private(set) var progress: Double = 0
    @Published var lastError: String?

    private let category: LogCategory
    private var task: Task<Void, Never>?

    /// Nonisolated: the location is a constant, and tests and background code
    /// need it without hopping to the main actor.
    nonisolated static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Keyed by bundle identifier, not product name: another app already
        // owns ~/Library/Application Support/Relay on some machines, and
        // "Relay" is a common enough name that it will happen again.
        return base.appendingPathComponent("co.kevel.Relay/Models", isDirectory: true)
    }

    init(category: LogCategory) {
        self.category = category
        refresh()
    }

    func url(for model: Model) -> URL {
        Self.directory.appendingPathComponent(model.fileName)
    }

    func isInstalled(_ model: Model) -> Bool { installed.contains(model) }

    func refresh() {
        installed = Set(Model.allCases.filter { model in
            let path = url(for: model).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int64 else { return false }
            // A partial file from an interrupted download would otherwise look
            // installed and then fail to load.
            return size > model.approximateBytes / 2
        })
    }

    func download(_ model: Model) {
        guard downloading == nil else { return }
        downloading = model
        progress = 0
        lastError = nil

        task = Task {
            do {
                try await performDownload(model)
                Log.info(category, "\(model.displayName) model installed")
            } catch is CancellationError {
                Log.info(category, "Download cancelled")
            } catch {
                lastError = error.localizedDescription
                Log.error(category, "Download failed: \(error.localizedDescription)")
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

    func delete(_ model: Model) {
        try? FileManager.default.removeItem(at: url(for: model))
        Log.info(category, "\(model.displayName) model removed")
        refresh()
    }

    private func performDownload(_ model: Model) async throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)

        let destination = url(for: model)
        let partial = destination.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        Log.info(category, "Downloading \(model.displayName) model…")
        let (bytes, response) = try await URLSession.shared.bytes(from: model.downloadURL)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "ModelStore", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))",
            ])
        }

        let expected = response.expectedContentLength > 0
            ? response.expectedContentLength
            : model.approximateBytes

        // Buffer writes; a byte-at-a-time FileHandle write on a large model
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

/// The two stores the app uses.
extension ModelStore where Model == WhisperModel {
    static let whisper = ModelStore<WhisperModel>(category: .whisper)
}

extension ModelStore where Model == SpeakerModel {
    static let speaker = ModelStore<SpeakerModel>(category: .speakers)
}
