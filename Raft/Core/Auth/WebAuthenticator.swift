import AuthenticationServices
import UIKit

/// Runs the browser sign-in page in `ASWebAuthenticationSession` and returns the callback URL
/// (`raft://login/callback?...`).
@MainActor
final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var running: ASWebAuthenticationSession?

    /// - Parameter ephemeral: no shared Safari cookies (a clean sign-in each time).
    func authenticate(url: URL, callbackScheme: String, ephemeral: Bool = false) async throws -> URL {
        running?.cancel()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(callbackScheme)) { [weak self] callbackURL, error in
                Task { @MainActor in self?.running = nil }
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: AuthFlowError.cancelled)
                } else {
                    continuation.resume(throwing: AuthFlowError.browserError(error.map { String(describing: type(of: $0)) } ?? "no_callback"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = ephemeral
            running = session
            if !session.start() {
                running = nil
                continuation.resume(throwing: AuthFlowError.browserError("start_failed"))
            }
        }
    }

    func cancel() {
        running?.cancel()
        running = nil
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first {
                return window
            }
            guard let scene = scenes.first else { preconditionFailure("Browser sign-in needs a window scene") }
            return UIWindow(windowScene: scene)
        }
    }
}
