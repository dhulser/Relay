import SwiftUI

/// Download state for one on-demand model: progress, downloaded, or a button.
struct ModelDownloadRow<Model: DownloadableModel>: View {
    @ObservedObject var store: ModelStore<Model>
    let model: Model
    /// What to call it in the row, e.g. "Speaker model".
    let label: String

    var body: some View {
        if store.downloading == model {
            HStack {
                ProgressView(value: store.progress).tint(RelayTheme.accent)
                Text("\(Int(store.progress * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { store.cancelDownload() }.buttonStyle(.link)
            }
            .font(.system(size: 11.5))
        } else if store.isInstalled(model) {
            HStack {
                Label("\(label) downloaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(RelayTheme.listening)
                Spacer()
                Button("Remove") { store.delete(model) }.buttonStyle(.link)
            }
            .font(.system(size: 11.5))
        } else {
            HStack {
                Text("\(label) not downloaded (\(Self.size(model.approximateBytes)))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download") { store.download(model) }
                    .disabled(store.downloading != nil)
            }
            .font(.system(size: 11.5))
        }

        if let error = store.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(RelayTheme.working)
        }
    }

    private static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9)
            : bytes >= 1_000_000 ? "\(bytes / 1_000_000) MB"
            : "\(max(1, bytes / 1_000)) KB"
    }
}
