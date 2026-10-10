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
    /// Where the login has got to (`WebLoginProgress`). The interactive sheet ignores it; the
    /// silent re-login uses it to decide when to stop waiting and hand over to the sheet, since
    /// a hidden login form can never be filled in.
    var onProgress: (@MainActor (WebLoginProgress) -> Void)? = nil

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(serverHost: serverHost, onLoginComplete: onLoginComplete, onProgress: onProgress)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let serverHost: String
        private let onLoginComplete: @MainActor () -> Void
        private let onProgress: (@MainActor (WebLoginProgress) -> Void)?
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
            onProgress: (@MainActor (WebLoginProgress) -> Void)? = nil,
            captureCookies: @escaping (_ completion: @escaping @MainActor () -> Void) -> Void = { completion in
                WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                    syncCookies(cookies, into: HTTPCookieStorage.shared)
                    Task { @MainActor in completion() }
                }
            }
        ) {
            self.serverHost = serverHost
            self.onLoginComplete = onLoginComplete
            self.onProgress = onProgress
            self.captureCookies = captureCookies
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            handleNavigationStarted()
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            handleNavigation(to: webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            handleFinishedNavigation(to: webView.url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleFailedNavigation(error: error)
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            handleFailedNavigation(error: error)
        }

        /// A new load began — a redirect target, a self-submitting form, the SPA moving on — so
        /// whatever page last looked stopped was not the end of the chain.
        func handleNavigationStarted() {
            report(.navigating)
        }

        /// A load failed. One navigation merely *superseded* by the next (cancelled, or a frame
        /// load interrupted by a policy change) is not a stop: the chain is still moving.
        func handleFailedNavigation(error: Error) {
            guard !isSupersededNavigationError(error) else { return }
            report(.stopped)
        }

        /// A page finished loading. On the server host this is the same completion check as
        /// `didCommit`; anywhere else the chain has come to rest on a page of its own — an OIDC
        /// redirect chain is server-side 302s, which finish only at their destination — so it
        /// is reported as stopped. (A `form_post` IdP page that submits itself also finishes
        /// first; the silent re-login gives such a page a short grace before acting on this.)
        func handleFinishedNavigation(to url: URL?) {
            handleNavigation(to: url)
            guard let url, url.host?.caseInsensitiveCompare(serverHost) != .orderedSame else { return }
            report(.stopped)
        }

        /// Nothing is reported once the login has reached the server: what the signed-in web app
        /// does next is not part of the login.
        private func report(_ progress: WebLoginProgress) {
            guard !didComplete else { return }
            onProgress?(progress)
        }

        /// Shared completion core for every observed navigation event. Completes
        /// the login the first time the web view reaches the app on `serverHost`
        /// (a non-API path); ignored on the IdP host and on `/api/v1.0/*` hops.
        func handleNavigation(to url: URL?) {
            guard !didComplete,
                let url,
                isLoginNavigationComplete(url: url, serverHost: serverHost)
            else { return }
            // Reported before the asynchronous cookie capture, so nothing waiting on this login
            // can give up on it in the gap between arriving and confirming.
            onProgress?(.reachedServer)
            didComplete = true

            captureCookies { [onLoginComplete] in
                onLoginComplete()
            }
        }
    }
}

/// How far a `WebLoginView` login has got, for a caller that cannot watch the page.
enum WebLoginProgress: Equatable, Sendable {
    /// A load began; any earlier stop was not the end of the chain.
    case navigating
    /// The chain came to rest short of the signed-in app: a page off the server host finished
    /// loading (an IdP login form, or a `form_post` page about to submit itself), or a load failed.
    case stopped
    /// The web view is back on the server, signed in. The cookie hand-off and the completion
    /// callback follow.
    case reachedServer
}

/// A navigation that failed only because another replaced it: `NSURLErrorCancelled`, or WebKit's
/// "frame load interrupted" (102) — what a redirect or a download-policy decision produces.
func isSupersededNavigationError(_ error: Error) -> Bool {
    let error = error as NSError
    if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return true }
    return error.domain == "WebKitErrorDomain" && error.code == 102
}
