import SwiftUI

/// Download state for the speaker-embedding model, mirroring the Whisper row.
struct SpeakerModelRow: View {
    @ObservedObject private var store = ModelStore.speaker

    var body: some View {
        let model = SpeakerModel.campPlus

        if store.downloading == model {
            HStack {
                ProgressView(value: store.progress)
                Text("\(Int(store.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { store.cancelDownload() }
            }
        } else if store.isInstalled(model) {
            HStack {
                Label("Speaker model downloaded", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Spacer()
                Button("Remove") { store.delete(model) }
                    .font(.caption)
            }
        } else {
            HStack {
                Text("Speaker model not downloaded (27 MB)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download") { store.download(model) }
                    .disabled(store.downloading != nil)
            }
        }

        if let error = store.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
