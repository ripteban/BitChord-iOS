import Foundation
import WebKit

/// Native stand-in for the BitChord browser extension
/// (web/extension/entrypoints/background.ts). The injected relay script hands
/// it the page's bridge requests; it answers them the way the extension would.
///
/// Message shapes (from inject.js):
/// - `{kind: "bridge", method, params}` → `{ok: true, result}` | `{ok: false, error: {code, message}}`
/// - `{kind: "fetch", url, method, headers, body?}` (body base64) → `{status, statusText, headers, body, url}`
/// - `{kind: "log", level, message}` → nothing (console forwarding, for debugging)
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "bitchord"
    static let version = "ios-1.0"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            replyHandler(nil, "bad message")
            return
        }
        switch kind {
        case "log":
            NSLog("[BitChord][js:%@] %@", body["level"] as? String ?? "log", body["message"] as? String ?? "")
            replyHandler(nil, nil)
        case "fetch":
            Task { @MainActor in
                do {
                    replyHandler(try await self.rawFetch(body), nil)
                } catch {
                    replyHandler(nil, error.localizedDescription)
                }
            }
        case "bridge":
            let method = body["method"] as? String ?? ""
            let params = body["params"] as? [String: Any] ?? [:]
            Task { @MainActor in
                replyHandler(await self.handle(method: method, params: params), nil)
            }
        default:
            replyHandler(nil, "unknown kind \(kind)")
        }
    }

    // MARK: Bridge methods

    private func ok(_ result: Any) -> [String: Any] { ["ok": true, "result": result] }

    private func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": ["code": code, "message": message]]
    }

    private func handle(method: String, params: [String: Any]) async -> [String: Any] {
        do {
            switch method {
            case "ping":
                return ok([
                    "version": Self.version,
                    "protocol": 1,
                    "browser": "firefox",
                    "capabilities": ["yt", "lyrics"],
                ])
            case "yt.fetch":
                if params["auth"] as? Bool == true {
                    return fail("unauthenticated", "Signing in to YouTube Music isn't available in the iOS app yet.")
                }
                let url = params["url"] as? String ?? ""
                guard url.hasPrefix("https://www.youtube.com/api/jnn/") else {
                    return fail("forbidden", "yt.fetch doesn't serve \(url)")
                }
                return ok(try await httpExchange(params, youtubeOriginForApi: true))
            case "yt.authState":
                return ok([
                    "browserSignedIn": false,
                    "connected": false,
                    "signedIn": false,
                    "accounts": [Any](),
                    "active": NSNull(),
                    "problem": NSNull(),
                ])
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
        } catch let error as URLError {
            return fail("network", error.localizedDescription)
        } catch {
            return fail("internal", error.localizedDescription)
        }
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
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
        }
        let type = headers["content-type"] ?? ""
        let textual = type.range(of: "json|text|javascript|xml", options: .regularExpression) != nil
        let text = textual ? String(data: data, encoding: .utf8) : nil
        return [
            "status": http.statusCode,
            "headers": headers,
            "url": http.url?.absoluteString ?? urlString,
            "bodyEncoding": text != nil ? "text" : "base64",
            "body": text ?? data.base64EncodedString(),
        ]
    }

    /// The page's own non-GET cross-origin fetches (InnerTube POSTs and the like).
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
        return [
            "status": http.statusCode,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            "headers": NetRules.pageHeaders(from: http),
            "url": http.url?.absoluteString ?? urlString,
            "body": data.base64EncodedString(),
        ]
    }
}
