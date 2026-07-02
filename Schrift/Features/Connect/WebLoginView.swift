import SwiftUI
import WebKit

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
        private var didComplete = false

        init(serverHost: String, onLoginComplete: @escaping @MainActor () -> Void) {
            self.serverHost = serverHost
            self.onLoginComplete = onLoginComplete
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !didComplete,
                  let url = webView.url,
                  isLoginNavigationComplete(url: url, serverHost: serverHost) else { return }
            didComplete = true

            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                syncCookies(cookies, into: HTTPCookieStorage.shared)
                Task { @MainActor in
                    self.onLoginComplete()
                }
            }
        }
    }
}
