import SwiftUI
import WebKit

/// Hosts the server's OIDC login in a `WKWebView` and reports back once the flow
/// has returned to the authenticated app on the chosen server host.
///
/// Completion is evaluated on **both** `didCommit` and `didFinish` — not only on
/// a single final page load. The redirect chain is identical whether or not the
/// user has 2FA enabled (the IdP handles the OTP step internally, then issues the
/// usual `302 → /api/v1.0/callback/ → 302 → server root`), so the target URL is
/// correct in both cases. The problem a `didFinish`-only detector hit was that a
/// multi-step 2FA sign-in, together with the docs SPA's immediate client-side
/// `/` → `/home/` redirect, can supersede or drop the final full page-load event
/// — leaving the sheet stuck open even though the user is logged in. A cross-site
/// navigation back to the server host always *commits*, so keying off `didCommit`
/// as well makes detection robust to that timing without changing which URL we
/// accept. Detection stays bound to the exact `serverHost`, and the view model's
/// native `GET /users/me/` confirmation still rejects any false positive.
struct WebLoginView: UIViewRepresentable {
    let url: URL
    let serverHost: String
    let onLoginComplete: @MainActor () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(serverHost: serverHost, onLoginComplete: onLoginComplete)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let serverHost: String
        private let onLoginComplete: @MainActor () -> Void
        /// Syncs the web view's cookies into `HTTPCookieStorage.shared` (so the
        /// native API client inherits the freshly authenticated session), then
        /// runs `completion` on the main actor. Injected as a seam so tests can
        /// drive completion without a live WebKit cookie store; the completion is
        /// `@MainActor` (hence `Sendable`) so no non-`Sendable` cookie value ever
        /// crosses a concurrency boundary.
        private let captureCookies: (_ completion: @escaping @MainActor () -> Void) -> Void
        /// Latches the one-shot completion so the several navigation callbacks a
        /// single login produces report back exactly once.
        private var didComplete = false

        init(
            serverHost: String,
            onLoginComplete: @escaping @MainActor () -> Void,
            captureCookies: @escaping (_ completion: @escaping @MainActor () -> Void) -> Void = { completion in
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                    syncCookies(cookies, into: HTTPCookieStorage.shared)
                    Task { @MainActor in completion() }
                }
            }
        ) {
            self.serverHost = serverHost
            self.onLoginComplete = onLoginComplete
            self.captureCookies = captureCookies
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            handleNavigation(to: webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            handleNavigation(to: webView.url)
        }

        /// Shared completion core for every observed navigation event. Completes
        /// the login the first time the web view reaches the app on `serverHost`
        /// (a non-API path); ignored on the IdP host and on `/api/v1.0/*` hops.
        func handleNavigation(to url: URL?) {
            guard !didComplete,
                let url,
                isLoginNavigationComplete(url: url, serverHost: serverHost)
            else { return }
            didComplete = true

            captureCookies { [onLoginComplete] in
                onLoginComplete()
            }
        }
    }
}
