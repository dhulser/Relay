import SwiftUI

/// Tick the running apps Relay should hear. Apps chosen earlier that are not
/// open right now stay listed, greyed, so a choice survives a relaunch.
struct AppPickerList: View {
    @EnvironmentObject private var appState: AppState
    @State private var running: [ListenableApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(running) { app in
                        Toggle(app.name, isOn: binding(for: app.bundleID))
                            .toggleStyle(.checkbox)
                    }
                    ForEach(chosenButClosed, id: \.self) { bundleID in
                        Toggle("\(shortName(bundleID))  ·  not open", isOn: binding(for: bundleID))
                            .toggleStyle(.checkbox)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 150)

            HStack {
                Text(running.isEmpty ? "No apps open" : "\(appState.chosenApps.count) chosen")
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Refresh") { refresh() }.buttonStyle(.link)
            }
            .font(.system(size: 11))
        }
        .font(.system(size: 12.5))
        .onAppear(perform: refresh)
    }

    private var chosenButClosed: [String] {
        let open = Set(running.map(\.bundleID))
        return appState.chosenApps.filter { !open.contains($0) }.sorted()
    }

    private func binding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { appState.chosenApps.contains(bundleID) },
            set: { on in
                if on { appState.chosenApps.insert(bundleID) } else { appState.chosenApps.remove(bundleID) }
            }
        )
    }

    private func refresh() {
        running = ListenableApp.running
    }

    private func shortName(_ bundleID: String) -> String {
        bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
