import SwiftUI

/// Developer screen over the core: environment, sign-in (password, browser, two-step), servers
/// and the realtime connection. Not product UI.
struct DebugCoreView: View {
    @State private var model = DebugCoreModel()

    var body: some View {
        NavigationStack {
            Form {
                environmentSection
                if let session = model.session {
                    accountSection(session)
                    serversSection(session)
                    realtimeSection
                } else if let prompt = model.prompt {
                    secondFactorSection(prompt)
                } else {
                    signInSection
                }
                if let status = model.statusLine {
                    Section("Result") {
                        Text(verbatim: status)
                            .font(.callout)
                            .accessibilityIdentifier("status-line")
                    }
                }
                diagnosticsSection
                Section {
                    MadeWithAirBuild()
                }
            }
            .navigationTitle("Raft Core")
            .disabled(model.busy)
            .overlay {
                if model.busy { ProgressView().controlSize(.large) }
            }
        }
        .task { await model.start() }
    }

    // MARK: Sections

    private var environmentSection: some View {
        Section {
            Picker("Environment", selection: Binding(
                get: { model.environmentKind },
                set: { kind in Task { await model.switchEnvironment(to: kind) } }
            )) {
                ForEach(RaftEnvironment.Kind.allCases, id: \.self) { kind in
                    Text(verbatim: RaftEnvironment.of(kind).displayName).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("environment-picker")
            LabeledContent("API") {
                Text(verbatim: model.environment.apiBaseURL.absoluteString)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
        } header: {
            Text("Environment")
        }
    }

    private var signInSection: some View {
        Section("Sign in") {
            TextField("Email", text: $model.email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("email-field")
            SecureField("Password", text: $model.password)
                .textContentType(.password)
                .accessibilityIdentifier("password-field")
            Button("Sign in") {
                Task { await model.signIn() }
            }
            .disabled(model.email.isEmpty || model.password.isEmpty)
            .accessibilityIdentifier("sign-in-button")
            Button("Sign in with browser") {
                Task { await model.signInWithBrowser() }
            }
            .accessibilityIdentifier("browser-sign-in-button")
        }
    }

    private func secondFactorSection(_ prompt: SecondFactorPrompt) -> some View {
        Section {
            if prompt.passkeyOnly {
                Text("This account only has a passkey, which this app doesn't support yet. Use another method: an authenticator code or a backup code, or sign in with the browser.")
                    .font(.callout)
                    .accessibilityIdentifier("passkey-only-message")
                Button("Sign in with browser") {
                    Task { await model.signInWithBrowser() }
                }
            } else {
                if prompt.usableMethods.count > 1 {
                    Picker("Method", selection: $model.method) {
                        ForEach(prompt.usableMethods, id: \.self) { method in
                            Text(verbatim: method.displayName).tag(method)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("second-factor-method-picker")
                } else if let only = prompt.usableMethods.first {
                    LabeledContent("Method") { Text(verbatim: only.displayName) }
                }
                if prompt.methods.contains(.passkey) {
                    Text("Passkeys aren't supported here yet. Use another method.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField(model.method == .backupCode ? "Backup code" : "6-digit code", text: $model.code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(model.method == .backupCode ? .asciiCapable : .numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    .accessibilityIdentifier("second-factor-code-field")
                Button("Verify") {
                    Task { await model.submitSecondFactor() }
                }
                .disabled(model.code.isEmpty)
                .accessibilityIdentifier("second-factor-submit-button")
                #if DEBUG
                SecureField("TOTP secret (base32, debug only)", text: $model.totpSecret)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("totp-secret-field")
                Button("Fill code from secret") { model.fillCodeFromSecret() }
                    .disabled(model.totpSecret.isEmpty)
                    .accessibilityIdentifier("totp-fill-button")
                #endif
            }
            Button("Cancel", role: .cancel) { model.cancelSecondFactor() }
        } header: {
            Text("Two-step verification")
        } footer: {
            Text(verbatim: "Asked by \(prompt.refusedCall)")
        }
    }

    private func accountSection(_ session: StoredSession) -> some View {
        Section("Account") {
            LabeledContent("Name") { Text(verbatim: session.user.visibleName) }
            if let email = session.user.email {
                LabeledContent("Email") { Text(verbatim: email) }
            }
            LabeledContent("Profile setup") {
                Text(session.user.needsProfileSetup ? "Needed" : "Done")
            }
            Button("Reload account") { Task { await model.reloadAccount() } }
            Button("Sign out", role: .destructive) { Task { await model.signOut() } }
                .accessibilityIdentifier("sign-out-button")
        }
    }

    private func serversSection(_ session: StoredSession) -> some View {
        Section("Server") {
            if session.servers.isEmpty {
                Text("No servers")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Selected", selection: Binding(
                    get: { session.selectedServerId ?? "" },
                    set: { id in Task { await model.selectServer(id) } }
                )) {
                    ForEach(session.servers) { server in
                        Text(verbatim: server.name.isEmpty ? server.id : server.name).tag(server.id)
                    }
                }
                .accessibilityIdentifier("server-picker")
            }
        }
    }

    private var realtimeSection: some View {
        Section("Realtime") {
            LabeledContent("Socket") {
                Text(verbatim: model.socketStatus.description)
                    .foregroundStyle(model.socketStatus.isConnected ? .green : .secondary)
                    .accessibilityIdentifier("socket-status")
            }
            LabeledContent("Events") {
                Text(verbatim: "\(model.eventCount)")
                    .monospacedDigit()
                    .accessibilityIdentifier("socket-event-count")
            }
            if let last = model.lastEventName {
                LabeledContent("Last event") { Text(verbatim: last).font(.caption.monospaced()) }
            }
            Button("Reconnect") { Task { await model.reconnectRealtime() } }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Button("GET version") { Task { await model.fetchVersion() } }
                .accessibilityIdentifier("version-button")
            if let summary = model.versionSummary {
                Text(verbatim: summary)
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("version-summary")
            }
            ForEach(Array(model.log.prefix(12).enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    DebugCoreView()
}
