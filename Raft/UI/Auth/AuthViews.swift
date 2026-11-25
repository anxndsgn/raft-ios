import SwiftUI

/// Sign-in: Login (01/02) → two-step (03 ⇄ 04) → server choice (05/05b).
struct AuthFlowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.authPath) {
            Group {
                if model.session.phase == .signedIn && !model.signingOut {
                    ServerPickerView(showsBack: false)
                } else {
                    LoginView()
                }
            }
            .navigationDestination(for: AuthRoute.self) { route in
                switch route {
                case .totp: TwoFactorView()
                case .backupCode: BackupCodeView()
                case .servers: ServerPickerView(showsBack: false)
                }
            }
        }
        .tint(.raftTextPrimary)
        .onChange(of: model.session.phase) { _, phase in
            switch phase {
            case .secondFactor(let prompt):
                guard !prompt.passkeyOnly else { return }
                if model.authPath.last != .totp && model.authPath.last != .backupCode {
                    model.authPath = [prompt.usableMethods.contains(.totp) ? .totp : .backupCode]
                }
            case .signedOut, .signedIn, .restoring:
                model.authPath = []
            }
        }
        .onChange(of: model.authPath) { _, path in
            // Back from the code screens ends the attempt.
            if path.isEmpty, case .secondFactor = model.session.phase { model.session.cancelSecondFactor() }
        }
    }
}

// MARK: 01 / 02 Login

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("raft.termsAccepted") private var termsAccepted = false
    @State private var email = ""
    @State private var password = ""
    @State private var showsLegalError = false
    @State private var safariURL: URL?
    @State private var errorHaptic = 0
    @FocusState private var emailFocused: Bool
    @FocusState private var passwordFocused: Bool

    private var session: SessionStore { model.session }

    private var credentialsError: String? {
        session.failure == .incorrectCredentials ? L10n.t("auth_error_incorrect_credentials", "Incorrect email or password.") : nil
    }

    private var generalError: String? {
        switch session.failure {
        case .passkeyOnly: L10n.t("ios_error_passkey_only", "This account signs in with a passkey. Use Continue in browser.")
        case .offline: L10n.t("ios_error_offline", "You're offline. Check your connection and try again.")
        case .secondFactor(let result): result == .codeInvalid ? L10n.t("settings_step_up_code_invalid", "That code didn't work. Check the time on your phone is set automatically, then try the newest code.") : result.displayMessage
        case .other(let text): text
        case .incorrectCredentials, nil: nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if session.sessionExpired {
                    ErrorLine(text: L10n.t("error_session_expired", "Your session expired. Sign in again to continue."))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 12)
                        .padding(.bottom, -12)
                        .accessibilityIdentifier("session-expired")
                }
                Image("RaftMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 58)
                    .padding(.top, 52)
                    .padding(.bottom, 22)
                    .accessibilityLabel(Text(verbatim: "Raft"))
                    .accessibilityAddTraits(.isImage)
                Text(L10n.t("auth_web_login_button", "Sign in to Raft"))
                    .raftFont(.authTitle)
                    .foregroundStyle(Color.raftTextPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.t("ios_login_subtitle", "Where humans and AI agents build together."))
                    .raftFont(.callout)
                    .foregroundStyle(Color.raftTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                form.padding(.top, 32)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            // Signing out is busy too, but the form shows as it will stay (no greyed-out frame).
            .disabled(session.busy && !model.signingOut)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.raftCanvas.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safariSheet($safariURL)
        .sensoryFeedback(.error, trigger: errorHaptic)
        .onChange(of: session.failure) { _, failure in
            guard let failure else { return }
            errorHaptic += 1
            if failure == .incorrectCredentials {
                emailFocused = false
                passwordFocused = false
                AccessibilityNotification.Announcement(L10n.t("auth_error_incorrect_credentials", "Incorrect email or password.")).post()
            }
        }
        .onChange(of: email) { clearError() }
        .onChange(of: password) { clearError() }
    }

    private func clearError() {
        if session.failure != nil { session.clearFailure() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            RaftField(
                label: L10n.t("settings_account_email", "Email"),
                text: $email,
                contentType: .username,
                keyboard: .emailAddress,
                submitLabel: .next,
                onSubmit: { passwordFocused = true },
                focus: $emailFocused
            )
            .accessibilityIdentifier("login-email")
            RaftField(
                label: L10n.t("ios_password", "Password"),
                text: $password,
                isSecure: true,
                error: credentialsError,
                contentType: .password,
                submitLabel: .go,
                onSubmit: submit,
                focus: $passwordFocused
            )
            .padding(.top, 14)
            .accessibilityIdentifier("login-password")
            HStack {
                Spacer()
                Button {
                    safariURL = model.webURL("forgot-password")
                } label: {
                    Text(L10n.t("ios_forgot_password", "Forgot password?"))
                        .raftFont(.errorText)
                        .foregroundStyle(Color.raftTextSecondary)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            }
            .padding(.top, 4)
            termsRow
                .padding(.top, 14)
                .padding(.horizontal, 4)
            if showsLegalError {
                ErrorLine(text: L10n.t("auth_error_legal_acceptance_required", "Review and accept Raft’s Terms of Service and Privacy Policy to continue."))
                    .padding(.top, 8)
            }
            if let generalError {
                ErrorLine(text: generalError)
                    .padding(.top, 8)
                    .accessibilityIdentifier("login-error")
            }
            PrimaryButton(title: L10n.t("auth_action_sign_in", "Sign in"), isLoading: session.busy && !model.signingOut, action: submit)
                .padding(.top, 14)
                .accessibilityIdentifier("sign-in-button")
            orDivider.padding(.vertical, 16)
            SecondaryButton(title: L10n.t("settings_step_up_web_continue", "Continue in browser"), systemImage: "safari") {
                Task { await session.signInWithBrowser(using: model.webAuthenticator) }
            }
            .accessibilityIdentifier("browser-sign-in")
            Text(L10n.t("ios_browser_hint", "Opens app.raft.build in a secure browser sheet"))
                .raftFont(.caption)
                .foregroundStyle(Color.raftTextTertiary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
        }
    }

    private var termsRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                termsAccepted.toggle()
                if termsAccepted { showsLegalError = false }
            } label: {
                RaftCheckbox(isOn: termsAccepted)
                    .padding(13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(-13)
            .padding(.top, 1)
            Text(termsText)
                .raftFont(.footnote)
                .foregroundStyle(Color.raftTextSecondary)
                .tint(Color.raftTextPrimary)
                .environment(\.openURL, OpenURLAction { url in
                    safariURL = url
                    return .handled
                })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityRepresentation {
            Toggle(isOn: $termsAccepted) { Text(String(termsText.characters)) }
        }
        .accessibilityAction(named: Text(L10n.t("auth_link_terms_of_service", "Terms of Service"))) { safariURL = AppModel.termsURL }
        .accessibilityAction(named: Text(L10n.t("auth_link_privacy_policy", "Privacy Policy"))) { safariURL = AppModel.privacyURL }
        .accessibilityIdentifier("terms-checkbox")
    }

    private var termsText: AttributedString {
        func link(_ text: String, _ url: URL) -> AttributedString {
            var value = AttributedString(text)
            value.link = url
            value.foregroundColor = .raftTextPrimary
            value.underlineStyle = .single
            value.font = .custom(RaftFont.semibold, size: 13, relativeTo: .footnote)
            return value
        }
        var result = AttributedString(L10n.t("auth_terms_agreement_prefix", "I agree to the "))
        result += link(L10n.t("auth_link_terms_of_service", "Terms of Service"), AppModel.termsURL)
        result += AttributedString(L10n.t("auth_terms_agreement_connector", " and ") + L10n.t("auth_terms_agreement_acknowledgement", "acknowledge the "))
        result += link(L10n.t("auth_link_privacy_policy", "Privacy Policy"), AppModel.privacyURL)
        result += AttributedString(".")
        return result
    }

    private var orDivider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.raftFieldRing).frame(height: 0.5)
            Text(verbatim: L10n.t("auth_social_divider_or", "or").lowercased())
                .raftFont(.footnote)
                .foregroundStyle(Color.raftTextTertiary)
            Rectangle().fill(Color.raftFieldRing).frame(height: 0.5)
        }
        .accessibilityHidden(true)
    }

    private func submit() {
        guard termsAccepted else {
            showsLegalError = true
            errorHaptic += 1
            AccessibilityNotification.Announcement(L10n.t("auth_error_legal_acceptance_required", "Review and accept Raft’s Terms of Service and Privacy Policy to continue.")).post()
            return
        }
        emailFocused = false
        passwordFocused = false
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password
        Task { await session.signIn(email: email, password: password) }
    }
}

// MARK: 03 TOTP

struct TwoFactorView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var showsError = false
    @State private var errorHaptic = 0
    @FocusState private var focused: Bool

    private var session: SessionStore { model.session }

    private var prompt: SecondFactorPrompt? {
        if case .secondFactor(let prompt) = session.phase { return prompt }
        return nil
    }

    private var maskedEmail: String? {
        if case .signInChallenge(let challenge) = prompt?.stage { return Masking.email(challenge.maskedEmail) }
        return Masking.email(session.user?.email)
    }

    private var errorText: String? {
        guard showsError, let failure = session.failure else { return nil }
        switch failure {
        case .secondFactor(.codeInvalid): return L10n.t("settings_step_up_code_invalid", "That code didn't work. Check the time on your phone is set automatically, then try the newest code.")
        case .secondFactor(let result): return result.displayMessage
        case .offline: return L10n.t("ios_error_offline", "You're offline. Check your connection and try again.")
        case .other(let text): return text
        default: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("settings_account_two_step_title", "Two-step verification"))
                    .raftFont(.authTitleLeading)
                    .foregroundStyle(Color.raftTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                detail.padding(.top, 8)
                boxes
                    .padding(.top, 28)
                    .padding(.bottom, errorText == nil ? 24 : 12)
                if let errorText {
                    ErrorLine(text: errorText)
                        .padding(.bottom, 20)
                        .accessibilityIdentifier("totp-error")
                }
                PrimaryButton(
                    title: session.busy ? L10n.t("settings_step_up_verifying", "Verifying…") : L10n.t("settings_step_up_verify", "Verify"),
                    isLoading: false,
                    action: verify
                )
                .allowsHitTesting(!session.busy)
                .accessibilityIdentifier("verify-button")
                if prompt?.usableMethods.contains(.backupCode) ?? true {
                    LinkButton(title: L10n.t("settings_step_up_use_backup_code", "Use a backup code")) {
                        if !model.authPath.isEmpty { model.authPath[model.authPath.count - 1] = .backupCode }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                    .accessibilityIdentifier("use-backup-code")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .background(Color.raftCanvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.error, trigger: errorHaptic)
        .onAppear { focused = true }
        .onChange(of: session.failure) { _, failure in
            guard failure != nil else { return }
            showsError = true
            code = ""
            focused = true
            errorHaptic += 1
            if let errorText { AccessibilityNotification.Announcement(errorText).post() }
        }
    }

    private var detail: some View {
        let format = L10n.t("ios_totp_detail", "Enter the 6-digit code from your authenticator app for %1$@.")
        return Group {
            if let maskedEmail {
                Text.emphasized(format, maskedEmail, base: .callout, strongFont: RaftFont.semibold, strongColor: .raftTextPrimary)
            } else {
                Text(L10n.t("ios_totp_detail_plain", "Enter the 6-digit code from your authenticator app."))
                    .raftStyle(.callout)
            }
        }
        .foregroundStyle(Color.raftTextSecondary)
        .lineSpacing(RaftFont.callout.lineSpacing)
    }

    private var boxes: some View {
        let digits = Array(code)
        let active = min(digits.count, 5)
        return ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .opacity(0.02)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
                .onChange(of: code) { _, value in
                    let filtered = String(value.filter(\.isNumber).prefix(6))
                    if filtered != value { code = filtered }
                    if showsError && !filtered.isEmpty { showsError = false; session.clearFailure() }
                    if filtered.count == 6 { verify() }
                }
                .disabled(session.busy)
            HStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { index in
                    if index > 0 { Spacer(minLength: 4) }
                    CodeBox(
                        digit: index < digits.count ? String(digits[index]) : nil,
                        isActive: focused && index == active && !session.busy,
                        isError: showsError && errorText != nil
                    )
                }
            }
            .animation(.easeOut(duration: 0.12), value: active)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(L10n.t("settings_step_up_code_label", "Authenticator code")))
        .accessibilityValue(Text(L10n.f("ios_totp_progress", "%1$d of 6 digits entered", digits.count)))
        .accessibilityIdentifier("totp-boxes")
    }

    private func verify() {
        guard code.count == 6, !session.busy else { return }
        let value = code
        Task { await session.submitSecondFactor(.totp(value)) }
    }
}

private struct CodeBox: View {
    let digit: String?
    let isActive: Bool
    let isError: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        ZStack {
            shape.fill(isActive ? Color.raftYellow : Color.raftFieldFill)
            shape.strokeBorder(isError ? Color.raftRed : Color.raftInk, lineWidth: 1.5)
            if let digit {
                Text(verbatim: digit)
                    .font(RaftFont.monoDigit.font)
                    .foregroundStyle(isActive ? Color.raftInk : Color.raftTextPrimary)
            } else if isActive {
                RoundedRectangle(cornerRadius: 1).fill(Color.raftInk).frame(width: 2, height: 26)
            }
        }
        .frame(width: 50, height: 60)
        .dieCut(radius: 8)
        .shadow(color: isActive ? .raftInk : .clear, radius: 0, x: 3, y: 3)
    }
}

// MARK: 04 Backup code

struct BackupCodeView: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var showsError = false
    @State private var safariURL: URL?
    @State private var errorHaptic = 0
    @FocusState private var focused: Bool

    private var session: SessionStore { model.session }

    private var prompt: SecondFactorPrompt? {
        if case .secondFactor(let prompt) = session.phase { return prompt }
        return nil
    }

    private var errorText: String? {
        guard showsError, let failure = session.failure else { return nil }
        switch failure {
        case .secondFactor(.codeInvalid): return L10n.t("settings_step_up_backup_code_invalid", "That backup code didn't work. Check it and try again.")
        case .secondFactor(let result): return result.displayMessage
        case .offline: return L10n.t("ios_error_offline", "You're offline. Check your connection and try again.")
        case .other(let text): return text
        default: return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.t("settings_account_two_step_title", "Two-step verification"))
                    .raftFont(.authTitleLeading)
                    .foregroundStyle(Color.raftTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.t("ios_backup_detail", "Enter one of the backup codes you saved when you turned on two-step verification."))
                    .raftFont(.callout)
                    .foregroundStyle(Color.raftTextSecondary)
                    .padding(.top, 8)
                RaftField(
                    label: L10n.t("settings_step_up_backup_code_label", "Backup code"),
                    text: $code,
                    placeholder: "xxxx-xxxx",
                    error: errorText,
                    mono: true,
                    contentType: .oneTimeCode,
                    keyboard: .asciiCapable,
                    submitLabel: .go,
                    onSubmit: verify,
                    focus: $focused
                )
                .padding(.top, 28)
                .accessibilityIdentifier("backup-code-field")
                if errorText == nil {
                    help.padding(.top, 8).padding(.leading, 4)
                }
                PrimaryButton(
                    title: session.busy ? L10n.t("settings_step_up_verifying", "Verifying…") : L10n.t("settings_step_up_verify", "Verify"),
                    action: verify
                )
                .allowsHitTesting(!session.busy)
                .padding(.top, 24)
                .accessibilityIdentifier("verify-button")
                VStack(spacing: 0) {
                    if prompt?.usableMethods.contains(.totp) ?? true {
                        LinkButton(title: L10n.t("settings_step_up_use_authenticator", "Use authenticator code")) {
                            if !model.authPath.isEmpty { model.authPath[model.authPath.count - 1] = .totp }
                        }
                        .padding(.top, 6)
                    }
                    LinkButton(title: L10n.t("settings_step_up_lost_authenticator", "Lost the device with your authenticator?"), underline: false, weak: true) {
                        safariURL = model.webURL("login")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
        .background(Color.raftCanvas.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .safariSheet($safariURL)
        .sensoryFeedback(.error, trigger: errorHaptic)
        .onAppear { focused = true }
        .onChange(of: code) { _, value in
            let formatted = Self.format(value)
            if formatted != value { code = formatted }
            if showsError { showsError = false; session.clearFailure() }
        }
        .onChange(of: session.failure) { _, failure in
            guard failure != nil else { return }
            showsError = true
            errorHaptic += 1
            if let errorText { AccessibilityNotification.Announcement(errorText).post() }
        }
    }

    private var help: some View {
        let format = L10n.t("ios_backup_help", "A backup code works once. Format: %1$@")
        let parts = format.components(separatedBy: "%1$@")
        return (Text(verbatim: parts.first ?? "").raftStyle(.footnote)
            + Text(verbatim: "xxxx-xxxx").font(RaftFont.monoCaption.font)
            + Text(verbatim: parts.count > 1 ? parts[1] : "").raftStyle(.footnote))
            .foregroundStyle(Color.raftTextTertiary)
    }

    /// Letters and digits, a dash after the fourth (`xxxx-xxxx`).
    static func format(_ value: String) -> String {
        let characters = value.filter { $0.isLetter || $0.isNumber }
        let clipped = String(characters.prefix(8))
        guard clipped.count > 4 else { return clipped }
        return String(clipped.prefix(4)) + "-" + clipped.dropFirst(4)
    }

    private func verify() {
        let value = code.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !session.busy else { return }
        Task { await session.submitSecondFactor(.backupCode(value)) }
    }
}
