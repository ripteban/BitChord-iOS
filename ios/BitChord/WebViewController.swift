import SafariServices
import UIKit
import WebKit

/// Hosts the BitChord web app (bundled at www/) in a full-screen WKWebView.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private let schemeHandler = AppSchemeHandler()
    private let bridge = Bridge()

    /// The simulator smoke test (CI) and debug builds log the page's console to the system log.
    nonisolated static let diagnostics: Bool = {
        #if DEBUG
        return true
        #else
        return ProcessInfo.processInfo.arguments.contains("-autotest")
        #endif
    }()

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
        Self.unlockProMotion(config.preferences)

        let content = config.userContentController
        content.addScriptMessageHandler(bridge, contentWorld: .page, name: Bridge.name)
        let flags = "window.__bitchordDebug = \(Self.diagnostics);"
        content.addUserScript(WKUserScript(source: flags, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        if let url = Bundle.main.url(forResource: "inject", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8)
        {
            content.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        } else {
            NSLog("[BitChord] inject.js missing from the bundle")
        }

        webView = WKWebView(frame: .zero, configuration: config)
        bridge.webView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0x1f / 255, green: 0x1f / 255, blue: 0x1f / 255, alpha: 1)
        webView.scrollView.backgroundColor = webView.backgroundColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        // No pinch or double-tap zoom: it's an app, not a page.
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        view = webView
    }

    /// ProMotion: WebKit renders pages near 60 fps unless told otherwise. Flip that
    /// internal feature off when this WebKit has it (guarded: no-op where it doesn't).
    private static func unlockProMotion(_ preferences: WKPreferences) {
        let featuresSelector = NSSelectorFromString("_features")
        let setSelector = NSSelectorFromString("_setEnabled:forFeature:")
        let cls: AnyObject = WKPreferences.self
        guard cls.responds(to: featuresSelector), preferences.responds(to: setSelector),
              let features = cls.perform(featuresSelector)?.takeUnretainedValue() as? [NSObject]
        else { return }
        for feature in features {
            guard let key = feature.value(forKey: "key") as? String else { continue }
            if key == "PreferPageRenderingUpdatesNear60FPSEnabled" {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
                let imp = preferences.method(for: setSelector)
                unsafeBitCast(imp, to: Setter.self)(preferences, setSelector, false, feature)
                NSLog("[BitChord] ProMotion: page rendering no longer capped near 60 fps")
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // `-route /debug` (simulator smoke test) opens a page other than home.
        var path = "/"
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-route"), i + 1 < args.count { path = args[i + 1] }
        webView.load(URLRequest(url: URL(string: AppSchemeHandler.origin + path)!))
    }

    // MARK: Navigation: the app stays on app://; Google sign-in opens in-app; the rest in Safari.

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
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        if ProcessInfo.processInfo.arguments.contains("-autotest"), !autotestStarted {
            autotestStarted = true
            runAutotest()
        }
    }

    private func openExternally(_ url: URL) {
        if url.host?.lowercased() == "accounts.google.com" {
            presentSignIn(url)
            return
        }
        guard url.scheme == "https" || url.scheme == "http" else {
            UIApplication.shared.open(url)
            return
        }
        present(SFSafariViewController(url: url), animated: true)
    }

    private func presentSignIn(_ url: URL) {
        guard presentedViewController == nil else { return }
        let signIn = SignInViewController(url: url) { [weak self] _ in self?.bridge.signInFinished() }
        let nav = UINavigationController(rootViewController: signIn)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    // MARK: Simulator smoke test (CI): play a Debug-page test track and report.

    private var autotestStarted = false

    private func runAutotest() {
        let probe = """
        (() => {
          const m = document.querySelector('audio, video');
          const mini = document.querySelector('[aria-label^="Now playing"]');
          const r = mini && mini.getBoundingClientRect();
          const log = [...document.querySelectorAll('pre, [class*="monospace"]')].map(e => e.innerText).join('\\n').slice(-1200);
          return JSON.stringify({
            path: location.pathname, secure: window.isSecureContext,
            media: m ? { paused: m.paused, t: m.currentTime, rs: m.readyState, err: m.error && m.error.code } : null,
            mini: r ? { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) } : null,
            fullScreen: !!document.querySelector('[data-full-screen]'),
            zoom: document.querySelector('meta[name=viewport]')?.content,
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
        let iframeTest = #"""
        fetch('https://www.youtube.com/iframe_api').then(async r => {
          const t = await r.text();
          console.warn('[iframe_api test] status', r.status, 'len', t.length, 'match', t.includes('player' + String.fromCharCode(92) + '/'));
        }).catch(e => console.error('[iframe_api test] failed', String(e)));
        fetch('https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=en&dt=t&q=' + encodeURIComponent('I love you'))
          .then(r => r.json()).then(j => console.warn('[translate test]', JSON.stringify(j[0])))
          .catch(e => console.error('[translate test] failed', String(e)));
        'started'
        """#
        func eval(_ js: String, _ label: String) {
            webView.evaluateJavaScript(js) { result, error in
                NSLog("[BitChord][autotest] %@: %@", label, String(describing: result ?? error))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { eval(iframeTest, "iframe@3s") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { eval(probe, "probe@6s") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { eval(click, "click@8s") }
        // The CI script taps the mini player for real (idb) around 25s; these show the result.
        for t in stride(from: 12.0, through: 100.0, by: 4.0) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { eval(probe, "probe@\(Int(t))s") }
        }
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
