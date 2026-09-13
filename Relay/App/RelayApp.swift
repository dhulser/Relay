import SwiftUI

@main
struct RelayApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            // The same waveform used in the popover header, so the menu bar and
            // the app read as one thing. It fills while a session is running,
            // which makes "is this on?" answerable without opening anything.
            Image(systemName: appState.status == .listening ? "waveform.circle.fill" : "waveform")
            Text("Relay")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
