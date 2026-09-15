import SwiftUI

/// Relay Hosted in Settings: sign up, or see the account and this month's use.
struct HostedSection: View {
    @ObservedObject var hosted: HostedAccount
    @State private var code = ""
    @State private var enteringCode = false
    @State private var copied = false
    @State private var workEmail = ""

    /// Names what is actually in the section: a company account once signed
    /// in to one, Relay Hosted when that is on offer, otherwise the only
    /// thing on show, which is company sign-in.
    private var sectionTitle: String {
        if hosted.isCompany { return "Your company's account" }
        if hosted.isSignedIn || HostedAccount.offered { return "Relay Hosted" }
        return "Your company"
    }

    var body: some View {
        Section(sectionTitle) {
            if hosted.isSignedIn {
                if hosted.isCompany { companyAccount } else { account }
            } else {
                companySignIn
                if HostedAccount.offered { offer }
            }

            if let error = hosted.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RelayTheme.working)
            }
        }
        .task { await hosted.refreshUsage() }
    }

    // MARK: - Company sign-in

    @ViewBuilder
    private var companySignIn: some View {
        Text("Does your company run Relay? Sign in with your work account and its keys are used for you, with nothing to set up.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        HStack {
            TextField("", text: $workEmail, prompt: Text("you@company.com"))
                .textContentType(.emailAddress)
                .onSubmit { signIn() }
            Button("Sign in with your company") { signIn() }
                .disabled(!workEmail.contains("@") || hosted.busy)
        }
        if !HostedAccount.offered {
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
    }

    private func signIn() {
        guard workEmail.contains("@") else { return }
        hosted.signInWithCompany(email: workEmail)
    }

    // MARK: - Company account

    @ViewBuilder
    private var companyAccount: some View {
        Toggle("Use \(hosted.companyName ?? "your company")'s account", isOn: $hosted.enabled)
        if let usage = hosted.usage {
            LabeledContent("Signed in as") {
                Text("\(usage.member?.email ?? "") · \(usage.org?.name ?? "")")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("This month") {
                Text("\(usage.localMinutes) min Local · \(usage.instantMinutes) min Instant")
                    .foregroundStyle(.secondary)
            }
        }
        Text(hosted.enabled
             ? "Local and Instant run on your company's keys. Relay keeps minutes, never what was said."
             : "Signed in, but using your own keys. Turn this on to switch back.")
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
    }

    // MARK: - Not signed in

    @ViewBuilder
    private var offer: some View {
        Text("Rather not manage a key? Relay brings the keys. $2 a month, plus 40¢ an hour for Local mode "
             + "and $3.50 an hour for Instant, only while listening. Capped at $50 a month.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

        HStack {
            Button("Sign up") { Task { await hosted.beginCheckout() } }
                .disabled(hosted.busy)
            Button(enteringCode ? "Cancel" : "I have a code") { enteringCode.toggle(); code = "" }
                .buttonStyle(.link)
            Spacer()
        }

        if enteringCode {
            HStack {
                SecureField("", text: $code, prompt: Text("rly_…"))
                    .onSubmit { activate() }
                Button("Activate") { activate() }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || hosted.busy)
            }
        }
    }

    private func activate() {
        let token = code
        code = ""
        enteringCode = false
        Task { await hosted.activate(token: token) }
    }

    // MARK: - Signed in

    @ViewBuilder
    private var account: some View {
        Toggle("Use Relay Hosted", isOn: $hosted.enabled)
        Text(hosted.enabled
             ? "Local and Instant run through Relay with our keys. Your own keys, if any, are not used."
             : "Signed in, but using your own keys. Turn this on to switch back.")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

        if let usage = hosted.usage {
            LabeledContent("This month") {
                Text("\(usage.localMinutes) min Local · \(usage.instantMinutes) min Instant · about \(usage.estimatedText) of \(usage.capText)")
                    .foregroundStyle(.secondary)
            }
            if usage.status != "active" && usage.status != "trialing" {
                Label("Subscription is \(usage.status.replacingOccurrences(of: "_", with: " ")). Check billing.",
                      systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(RelayTheme.working)
            }
        }

        HStack {
            Button("Manage billing") { Task { await hosted.openBilling() } }
            Button("Add another Mac") { Task { await hosted.mintTokenForAnotherMac() } }
            Spacer()
            Button("Sign out") { Task { await hosted.signOut() } }
                .buttonStyle(.link)
        }
        .disabled(hosted.busy)

        if let fresh = hosted.freshToken {
            VStack(alignment: .leading, spacing: 6) {
                Text("On the other Mac, open Settings, choose I have a code, and paste this. It is shown once.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                HStack {
                    Text(fresh)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(fresh, forType: .string)
                        copied = true
                    }
                    Button("Done") { hosted.freshToken = nil; copied = false }.buttonStyle(.link)
                }
            }
        }
    }
}
