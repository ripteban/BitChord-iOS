import UIKit
import WebKit

/// Google sign-in for YouTube Music, inside the app so the session lands in the
/// app's own cookie jar (WKWebsiteDataStore.default()), where YouTubeAuth reads it.
///
/// The page is Google's own: the password is typed there (iOS offers saved
/// Keychain passwords from the keyboard's key button), never seen by BitChord.
/// It closes itself once Google sends the browser back to YouTube.
final class SignInViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private let startURL: URL
    private let onFinish: @MainActor (_ signedIn: Bool) -> Void
    private var webView: WKWebView!
    private var finished = false

    init(url: URL, onFinish: @escaping @MainActor (_ signedIn: Bool) -> Void) {
        startURL = url
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Mobile Safari's own user agent: Google refuses sign-in in web views that announce themselves.
    static var safariUserAgent: String {
        let version = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
        let major = UIDevice.current.systemVersion.split(separator: ".").first ?? "18"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(version) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sign in to YouTube"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.finish(signedIn: false)
        })
        webView.load(URLRequest(url: startURL))
    }

    private func finish(signedIn: Bool) {
        guard !finished else { return }
        finished = true
        dismiss(animated: true) { [onFinish] in onFinish(signedIn) }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let host = navigationAction.request.url?.host?.lowercased() ?? ""
        // Back on YouTube: the session cookies are set. Give the jar a moment, then close.
        if navigationAction.targetFrame?.isMainFrame != false, host == "music.youtube.com" || host == "www.youtube.com" || host == "m.youtube.com" {
            decisionHandler(.cancel)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                self.finish(signedIn: await YouTubeAuth.shared.hasSession)
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Google's "help" and similar links: keep them in this sheet.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}
