import UIKit
import WebKit

/// BotGuard PO tokens, minted the way the Android app mints them
/// (app/.../potoken/PoTokenWebView.kt): in a hidden web view whose page has
/// YouTube's own origin (https://www.youtube.com), with the Create and
/// GenerateIT calls made natively. Tokens minted in the app's own page
/// (app://bitchord) were not accepted: googlevideo stopped those streams at 1 MiB.
@MainActor
final class PoToken: NSObject, WKNavigationDelegate {
    static let shared = PoToken()

    private static let apiKey = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
    private static let requestKey = "O43z0dpjhgX20SCx4KAo"
    private static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.3"

    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?
    private var ready: Task<Void, Error>?
    private var expires = Date.distantPast
    private var tokens: [String: String] = [:]

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A token bound to [identifier]: a visitor data, a video id or an account's DataSync ID.
    func mint(_ identifier: String) async throws -> String {
        if let known = tokens[identifier], Date() < expires { return known }
        do {
            return try await mintOnce(identifier)
        } catch {
            // One retry on a fresh page, as PoTokenGenerator does.
            Diag.log("po token: \(error.localizedDescription); retrying on a fresh page")
            reset()
            return try await mintOnce(identifier)
        }
    }

    private func mintOnce(_ identifier: String) async throws -> String {
        try await ensureReady()
        guard let webView else { throw Failure(message: "no BotGuard page") }
        let result = try await withTimeout(8) {
            try await webView.callAsyncJavaScript(Self.mintScript, arguments: ["identifier": identifier], contentWorld: .page)
        }
        guard let token = result as? String, !token.isEmpty else { throw Failure(message: "empty token") }
        if tokens.count > 200 { tokens.removeAll() }
        tokens[identifier] = token
        return token
    }

    private func reset() {
        webView?.removeFromSuperview()
        webView?.navigationDelegate = nil
        webView = nil
        ready = nil
        tokens.removeAll()
        expires = .distantPast
    }

    private func ensureReady() async throws {
        if ready != nil, Date() >= expires { reset() }
        if let ready { return try await ready.value }
        let task = Task { try await self.start() }
        ready = task
        do {
            try await task.value
        } catch {
            reset()
            throw error
        }
    }

    private func start() async throws {
        let began = Date()
        guard let file = Bundle.main.url(forResource: "potoken", withExtension: "html"),
              let html = try? String(contentsOf: file, encoding: .utf8)
        else { throw Failure(message: "potoken.html missing") }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        view.customUserAgent = Self.userAgent
        view.navigationDelegate = self
        // In the window (unseen): a web view outside any window gets its timers throttled.
        view.alpha = 0
        view.isUserInteractionEnabled = false
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first
        window?.insertSubview(view, at: 0)
        webView = view
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            loaded = continuation
            view.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com")!)
        }

        let challenge = try await service("Create", body: "[ \"\(Self.requestKey)\" ]")
        let response = try await withTimeout(15) {
            try await view.callAsyncJavaScript(Self.runScript, arguments: ["raw": challenge], contentWorld: .page)
        }
        guard let botguardResponse = response as? String else { throw Failure(message: "BotGuard gave no response") }

        let integrity = try await service("GenerateIT", body: "[ \"\(Self.requestKey)\", \"\(botguardResponse)\" ]")
        let lifetime = try await withTimeout(10) {
            try await view.callAsyncJavaScript(Self.minterScript, arguments: ["raw": integrity], contentWorld: .page)
        }
        let seconds = (lifetime as? NSNumber)?.doubleValue ?? 3600
        // Ten minutes of margin, as the phone leaves.
        expires = Date().addingTimeInterval(max(60, seconds - 600))
        Diag.log("po token: BotGuard ready on youtube.com in \(Int(Date().timeIntervalSince(began) * 1000))ms, valid \(Int(seconds / 60)) min")
    }

    private func service(_ name: String, body: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.youtube.com/api/jnn/v1/\(name)")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        for (key, value) in [
            "User-Agent": Self.userAgent,
            "Accept": "application/json",
            "Content-Type": "application/json+protobuf",
            "x-goog-api-key": Self.apiKey,
            "x-user-agent": "grpc-web-javascript/0.1",
        ] {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let text = String(data: data, encoding: .utf8) else {
            throw Failure(message: "\(name) answered HTTP \(status)")
        }
        return text
    }

    private func withTimeout<T>(_ seconds: Double, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let task = Task { @MainActor in try await work() }
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            task.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await task.value
        } catch is CancellationError {
            throw Failure(message: "timed out after \(Int(seconds))s")
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Diag.log("po token: BotGuard page's process ended")
        reset()
    }

    // MARK: The page's side (JavaScriptUtil.kt, in JavaScript)

    /// YouTube's base64: '-' '_' and '.' for '+' '/' and '='.
    private static let helpers = """
    const bytesOf = (b64) => Uint8Array.from(atob(b64.replace(/-/g, '+').replace(/_/g, '/').replace(/\\./g, '=')), (c) => c.charCodeAt(0));
    """

    /// parseChallengeData + runBotGuard: returns the BotGuard response.
    private static let runScript = helpers + """
    const scrambled = JSON.parse(raw);
    let data;
    if (scrambled.length > 1 && typeof scrambled[1] === 'string') {
      const bytes = bytesOf(scrambled[1]);
      let text = '';
      for (let i = 0; i < bytes.length; i++) text += String.fromCharCode((bytes[i] + 97) & 0xff);
      data = JSON.parse(decodeURIComponent(escape(text)));
    } else {
      data = scrambled[0];
    }
    const firstString = (list) => (Array.isArray(list) ? list.find((x) => typeof x === 'string') ?? null : null);
    const result = await runBotGuard({
      messageId: data[0],
      interpreterJavascript: {
        privateDoNotAccessOrElseSafeScriptWrappedValue: firstString(data[1]),
        privateDoNotAccessOrElseTrustedResourceUrlWrappedValue: firstString(data[2]),
      },
      interpreterHash: data[3],
      program: data[4],
      globalName: data[5],
      clientExperimentsStateBlob: data[7],
    });
    window.webPoSignalOutput = result.webPoSignalOutput;
    return result.botguardResponse;
    """

    /// parseIntegrityTokenData + createPoTokenMinter: returns the token's lifetime in seconds.
    private static let minterScript = helpers + """
    const parsed = JSON.parse(raw);
    await createPoTokenMinter(window.webPoSignalOutput, bytesOf(parsed[0]));
    return Number(parsed[1]);
    """

    /// obtainPoToken, encoded as u8ToBase64 does.
    private static let mintScript = """
    const token = await obtainPoToken(new TextEncoder().encode(identifier));
    let binary = '';
    for (let i = 0; i < token.length; i++) binary += String.fromCharCode(token[i]);
    return btoa(binary).replace(/\\+/g, '-').replace(/\\//g, '_');
    """
}
