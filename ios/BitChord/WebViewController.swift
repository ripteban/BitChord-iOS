import SafariServices
import UIKit
import WebKit

/// Hosts the BitChord web app (bundled at www/) in a full-screen WKWebView.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private let schemeHandler = AppSchemeHandler()
    private let bridge = Bridge()

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func loadView() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: AppSchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = false
        config.websiteDataStore = .default()
        config.applicationNameForUserAgent = "BitChordiOS/\(Bridge.version) Mobile/15E148 Safari/604.1"

        let content = config.userContentController
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: Bridge.name)
        if let url = Bundle.main.url(forResource: "inject", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8)
        {
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        } else {
            NSLog("[BitChord] inject.js missing from the bundle")
        }

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0x1f / 255, green: 0x1f / 255, blue: 0x1f / 255, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = true
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // `-route /debug` (simulator smoke test) opens a page other than home.
        var path = "/"
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-route"), i + 1 < args.count { path = args[i + 1] }
        webView.load(URLRequest(url: URL(string: AppSchemeHandler.origin + path)!))
    }

    // MARK: Navigation: the app stays on app://; everything else opens in Safari.

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
        if url.scheme == AppSchemeHandler.scheme || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" {
            return decisionHandler(.allow)
        }
        if navigationAction.targetFrame?.isMainFrame == false {
            return decisionHandler(.allow) // iframes (BotGuard, embeds)
        }
        openExternally(url)
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { openExternally(url) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("[BitChord] web content process terminated; reloading")
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("[BitChord] navigation failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("[BitChord] provisional navigation failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[BitChord] loaded \(webView.url?.absoluteString ?? "?")")
        if ProcessInfo.processInfo.arguments.contains("-autotest"), !autotestStarted {
            autotestStarted = true
            runAutotest()
        }
    }

    // MARK: Simulator smoke test (CI): play a Debug-page test track and report.

    private var autotestStarted = false

    private func runAutotest() {
        let probe = """
        (() => {
          const m = document.querySelector('audio, video');
          const log = [...document.querySelectorAll('pre, [class*="monospace"]')].map(e => e.innerText).join('\\n').slice(-1500);
          return JSON.stringify({
            path: location.pathname, origin: location.origin, secure: window.isSecureContext,
            media: m ? { paused: m.paused, t: m.currentTime, rs: m.readyState, err: m.error && m.error.code, src: String(m.currentSrc).slice(0, 60) } : null,
            buttons: document.querySelectorAll('button').length,
            log
          });
        })()
        """
        let click = """
        (() => {
          const b = [...document.querySelectorAll('ul button')].find(e => /Bohemian|Blinding/.test(e.innerText));
          if (b) { b.click(); return 'clicked ' + b.innerText; }
          return 'no test track button';
        })()
        """
        func eval(_ js: String, _ label: String) {
            webView.evaluateJavaScript(js) { result, error in
                NSLog("[BitChord][autotest] %@: %@", label, String(describing: result ?? error))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { eval(probe, "probe@6s") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { eval(click, "click@8s") }
        for t in [20.0, 40.0, 90.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { eval(probe, "probe@\(Int(t))s") }
        }
    }

    private func openExternally(_ url: URL) {
        guard url.scheme == "https" || url.scheme == "http" else {
            UIApplication.shared.open(url)
            return
        }
        present(SFSafariViewController(url: url), animated: true)
    }

    // MARK: JS dialogs

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }
}
