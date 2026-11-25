import Foundation
import WebKit

/// Native stand-in for the BitChord browser extension
/// (web/extension/entrypoints/background.ts). The injected relay script hands
/// it the page's bridge requests; it answers them the way the extension would.
///
/// Message shapes (from inject.js):
/// - `{kind: "bridge", method, params}` → `{ok: true, result}` | `{ok: false, error: {code, message}}`
/// - `{kind: "fetch", url, method, headers, body?}` (body base64) →
///   `{status, statusText, headers, url, text?}` or `{…, body}` (base64) for binary responses
/// - `{kind: "log", level, message}` → nothing (console forwarding, debug builds only)
@MainActor
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "bitchord"
    static let version = "ios-1.1"

    /// The page, for pushing events (`yt.authState`) the way the extension's port does.
    weak var webView: WKWebView?
    /// The page's state for the native tab bar and mini player (`{kind: "chrome", …}`).
    var onChrome: (([String: Any]) -> Void)?
    /// The drawer's "Diagnóstico" entry (`{kind: "diagnostics"}`).
    var onDiagnostics: (() -> Void)?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
                replyHandler(nil, "bad message")
                return
            }
            switch kind {
            case "diagnostics":
                self.onDiagnostics?()
                replyHandler(nil, nil)
            case "chrome":
                self.onChrome?(body)
                replyHandler(nil, nil)
            case "log":
                NSLog("[BitChord][js:%@] %@", body["level"] as? String ?? "log", body["message"] as? String ?? "")
                replyHandler(nil, nil)
            case "fetch":
                Task {
                    do {
                        replyHandler(try await self.rawFetch(body), nil)
                    } catch {
                        replyHandler(nil, error.localizedDescription)
                    }
                }
            case "bridge":
                let method = body["method"] as? String ?? ""
                let params = body["params"] as? [String: Any] ?? [:]
                Task { replyHandler(await self.handle(method: method, params: params), nil) }
            default:
                replyHandler(nil, "unknown kind \(kind)")
            }
        }
    }

    // MARK: Events

    func broadcast(event: String, data: Any) {
        let message: [String: Any] = [
            "channel": "bitchord-bridge",
            "direction": "event",
            "payload": ["event": event, "data": data],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: message), let text = String(data: json, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("window.postMessage(\(text), '*')", completionHandler: nil)
    }

    /// After the sign-in sheet closes: re-read the accounts and tell the page.
    func signInFinished() {
        Task {
            YouTubeAuth.shared.invalidate()
            broadcast(event: "yt.authState", data: await YouTubeAuth.shared.authState(refresh: true))
        }
    }

    // MARK: Bridge methods

    private func ok(_ result: Any) -> [String: Any] { ["ok": true, "result": result] }

    private func fail(_ code: String, _ message: String) -> [String: Any] {
        Diag.log("bridge \(code): \(message.prefix(200))")
        return ["ok": false, "error": ["code": code, "message": message]]
    }

    private func handle(method: String, params: [String: Any]) async -> [String: Any] {
        let auth = YouTubeAuth.shared
        do {
            switch method {
            case "ping":
                return ok([
                    "version": Self.version,
                    "protocol": 1,
                    "browser": "firefox",
                    "capabilities": ["yt", "yt.auth", "yt.stats", "lyrics"],
                ])
            case "yt.fetch":
                if params["auth"] as? Bool == true {
                    return ok(try await auth.signedYtFetch(params))
                }
                let url = params["url"] as? String ?? ""
                guard url.hasPrefix("https://www.youtube.com/api/jnn/") else {
                    return fail("forbidden", "yt.fetch doesn't serve \(url)")
                }
                return ok(try await httpExchange(params, youtubeOriginForApi: true))
            case "yt.authState":
                return ok(await auth.authState(refresh: params["refresh"] as? Bool == true))
            case "yt.selectChannel":
                let state = try await auth.selectChannel(params["channelId"] as? String ?? "")
                broadcast(event: "yt.authState", data: state)
                return ok(state)
            case "yt.setConnected":
                let state = await auth.setConnected(params["connected"] as? Bool == true)
                broadcast(event: "yt.authState", data: state)
                return ok(state)
            case "ios.pot":
                // A BotGuard PO token minted on youtube.com's origin (PoToken.swift).
                let identifier = params["identifier"] as? String ?? ""
                guard !identifier.isEmpty else { return fail("internal", "ios.pot needs an identifier") }
                do {
                    return ok(["token": try await PoToken.shared.mint(identifier)])
                } catch {
                    return fail("internal", "po token: \(error.localizedDescription)")
                }
            case "ios.http":
                // The iOS resolver's player requests, as any InnerTube client (iosResolver.ts).
                let url = params["url"] as? String ?? ""
                guard url.hasPrefix("https://www.youtube.com/youtubei/v1/") || url.hasPrefix("https://music.youtube.com/youtubei/v1/") else {
                    return fail("forbidden", "ios.http doesn't serve \(url)")
                }
                if params["auth"] as? Bool == true {
                    return ok(try await auth.signedYtFetch(params))
                }
                return ok(try await httpExchange(params, youtubeOriginForApi: false))
            case "ios.probe":
                // Does this media URL serve bytes at `offset`? (Past the point a refused stream stops.)
                guard let text = params["url"] as? String, let url = URL(string: text),
                      url.host?.hasSuffix("googlevideo.com") == true
                else { return fail("forbidden", "ios.probe is for media URLs") }
                let offset = params["offset"] as? Int ?? 0
                var request = NetRules.upstreamRequest(url: url, method: "GET", headers: [:], body: nil)
                request.setValue("bytes=\(offset)-\(offset + 1023)", forHTTPHeaderField: "Range")
                request.timeoutInterval = 12
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status != 206 && status != 200 { Diag.log("probe \(status) at byte \(offset) \(AppSchemeHandler.short(url))") }
                return ok(["status": status, "bytes": data.count])
            case "lyrics.fetch":
                return ok(try await httpExchange(params, youtubeOriginForApi: false))
            case "lyrics.permissions":
                // No per-host permission prompts on iOS: the app may reach every lyrics host.
                return ok(["granted": params["origins"] as? [String] ?? []])
            case "lyrics.requestPermissions":
                return ok([String: Any]())
            default:
                return fail("unsupported", "\(method) isn't available in the iOS app.")
            }
        } catch is YouTubeAuth.SignedOut {
            return fail("unauthenticated", "Not signed in to YouTube Music.")
        } catch let error as URLError {
            return fail("network", error.localizedDescription)
        } catch {
            return fail("internal", error.localizedDescription)
        }
    }

    /// An `HttpResponse` (bridge protocol) for a finished exchange.
    static func serialise(data: Data, response: HTTPURLResponse, fallbackURL: String) -> [String: Any] {
        var headers: [String: String] = [:]
        for (k, v) in response.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
        }
        let type = headers["content-type"] ?? ""
        let textual = type.range(of: "json|text|javascript|xml", options: .regularExpression) != nil
        let text = textual ? String(data: data, encoding: .utf8) : nil
        return [
            "status": response.statusCode,
            "headers": headers,
            "url": response.url?.absoluteString ?? fallbackURL,
            "bodyEncoding": text != nil ? "text" : "base64",
            "body": text ?? data.base64EncodedString(),
        ]
    }

    /// An `HttpRequest` from the bridge protocol, answered as an `HttpResponse`.
    private func httpExchange(_ params: [String: Any], youtubeOriginForApi: Bool) async throws -> [String: Any] {
        guard let urlString = params["url"] as? String, let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var body: Data?
        if let text = params["body"] as? String {
            body = (params["bodyEncoding"] as? String) == "base64" ? Data(base64Encoded: text) : Data(text.utf8)
        }
        let request = NetRules.upstreamRequest(
            url: url,
            method: (params["method"] as? String ?? "GET").uppercased(),
            headers: params["headers"] as? [String: String] ?? [:],
            body: body,
            youtubeOriginForApi: youtubeOriginForApi
        )
        let (data, response) = try await session.data(for: request)
        return Self.serialise(data: data, response: response as! HTTPURLResponse, fallbackURL: urlString)
    }

    /// The page's own non-GET cross-origin fetches (InnerTube POSTs and the like).
    /// Text bodies come back as text: no base64 round trip for the large JSON answers.
    private func rawFetch(_ body: [String: Any]) async throws -> [String: Any] {
        guard let urlString = body["url"] as? String, let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        let payload = (body["body"] as? String).flatMap { Data(base64Encoded: $0) }
        let request = NetRules.upstreamRequest(
            url: url,
            method: (body["method"] as? String ?? "GET").uppercased(),
            headers: body["headers"] as? [String: String] ?? [:],
            body: payload
        )
        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        var result: [String: Any] = [
            "status": http.statusCode,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            "headers": NetRules.pageHeaders(from: http),
            "url": http.url?.absoluteString ?? urlString,
        ]
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.range(of: "json|text|javascript|xml", options: .regularExpression) != nil, let text = String(data: data, encoding: .utf8) {
            result["text"] = text
        } else {
            result["body"] = data.base64EncodedString()
        }
        return result
    }
}
