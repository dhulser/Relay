import SwiftUI

/// Who pays for translation: you, Relay, or your employer. Sits at the top of
/// the Translation tab because it decides what every control under it means —
/// which engines are available, whether a model can be chosen, and whose key
/// is spent.
struct AccountSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var hosted: HostedAccount

    @State private var workEmail = ""
    @State private var code = ""
    @State private var enteringCode = false
    @State private var copiedToken = false

    var body: some View {
        Section("Account") {
            Picker("", selection: $hosted.mode) {
                ForEach(AccountMode.allCases) { mode in
                    Text(mode == .company ? (hosted.companyName ?? mode.title) : mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch hosted.mode {
            case .personal: personal
            case .hosted: hostedTier
            case .company: company
            }

            if let error = hosted.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RelayTheme.working)
            }
        }
        .task { await hosted.refreshUsage() }
    }

    // MARK: - Personal

    private var personal: some View {
        Text("Your own Anthropic or OpenAI key. You pay the provider directly, and "
             + "Relay is free.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
    }

    // MARK: - Relay Hosted

    @ViewBuilder
    private var hostedTier: some View {
        Text("Relay brings the keys. You add credit up front and it is used only for the "
             + "time Relay spends listening.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

        if !HostedAccount.offered {
            Label("Not open yet. Relay keeps using your own key until it is.",
                  systemImage: "clock")
                .font(.system(size: 11.5))
                .foregroundStyle(RelayTheme.working)
        } else if hosted.isSignedIn, !hosted.isCompany {
            usageRow
            HStack {
                Button("Manage billing") { Task { await hosted.openBilling() } }
                Spacer()
                Button("Sign out") { Task { await hosted.signOut() } }
                    .buttonStyle(.link)
            }
            .disabled(hosted.busy)
        } else {
            Button("Sign up") { Task { await hosted.beginCheckout() } }
                .disabled(hosted.busy)
        }
    }

    // MARK: - Company

    @ViewBuilder
    private var company: some View {
        if hosted.isSignedIn, hosted.isCompany {
            if let usage = hosted.usage {
                LabeledContent("Signed in as") {
                    Text(usage.member?.email ?? "")
                        .foregroundStyle(.secondary)
                }
            }
            usageRow
            Text("Local and Instant run on \(hosted.companyName ?? "your company")'s keys. "
                 + "Relay keeps minutes, never what was said.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            HStack {
                if hosted.isCompanyAdmin {
                    Button("Open admin console") { hosted.openAdminConsole() }
                }
                Spacer()
                Button("Sign out") { Task { await hosted.signOut() } }
                    .buttonStyle(.link)
            }
            .disabled(hosted.busy)
        } else {
            Text("If your company runs Relay, sign in with your work account and its keys "
                 + "are used for you, with nothing to set up.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            HStack {
                TextField("", text: $workEmail, prompt: Text("you@company.com"))
                    .textContentType(.emailAddress)
                    .onSubmit { signIn() }
                Button("Sign in") { signIn() }
                    .disabled(!workEmail.contains("@") || hosted.busy)
            }
            Button(enteringCode ? "Cancel" : "I have a code") { enteringCode.toggle(); code = "" }
                .buttonStyle(.link)
            if enteringCode {
                HStack {
                    SecureField("", text: $code, prompt: Text("rly_…"))
                        .onSubmit { activate() }
                    Button("Activate") { activate() }
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || hosted.busy)
                }
            }
        }

        if let fresh = hosted.freshToken {
            VStack(alignment: .leading, spacing: 6) {
                Text("On the other Mac, choose Company, then I have a code, and paste this. "
                     + "It is shown once.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                HStack {
                    Text(fresh)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(copiedToken ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fresh, forType: .string)
                        copiedToken = true
                    }
                    Button("Done") { hosted.freshToken = nil; copiedToken = false }
                        .buttonStyle(.link)
                }
            }
        }
    }

    // MARK: - Shared

    @ViewBuilder
    private var usageRow: some View {
        if let usage = hosted.usage {
            LabeledContent("This month") {
                Text("\(usage.localMinutes) min Local · \(usage.instantMinutes) min Instant")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func signIn() {
        guard workEmail.contains("@") else { return }
        hosted.signInWithCompany(email: workEmail)
    }

    private func activate() {
        let token = code
        code = ""
        enteringCode = false
        Task { await hosted.activate(token: token) }
    }
}
