import Foundation

/// The iOS counterpart of the browser extension's declarativeNetRequest rules
/// (web/extension/lib/rules.ts and lyricsFetch.ts). The page's cross-origin
/// requests are routed through native code, which can send the Origin and
/// Referer the server expects and answers the page without CORS.
enum NetRules {
    /// Headers that identify the page (or are WebKit's to set) and never travel upstream as-is.
    private static let dropped: Set<String> = [
        "origin", "referer", "x-origin", "host", "cookie", "content-length",
        "connection", "accept-encoding", "sec-fetch-dest", "sec-fetch-mode", "sec-fetch-site",
    ]

    private static func impersonate(_ origin: String, xOrigin: Bool = true) -> [String: String] {
        var h = ["Origin": origin, "Referer": origin + "/"]
        if xOrigin { h["X-Origin"] = origin }
        return h
    }

    /// The headers to add for `url`, mirroring rules 1–7 (YouTube) and 200–201 (lyrics).
    static func extraHeaders(for url: URL, youtubeOriginForApi: Bool = false) -> [String: String] {
        let host = url.host?.lowercased() ?? ""
        let path = url.path
        let query = url.query ?? ""

        if host == "music.youtube.com" && path.hasPrefix("/youtubei/") {
            return impersonate("https://music.youtube.com")
        }
        if host == "www.youtube.com" && path.hasPrefix("/youtubei/") {
            return impersonate("https://www.youtube.com")
        }
        if host == "www.youtube.com" && path.hasPrefix("/api/jnn/") {
            // BotGuard: Create is fetched from the page with no YouTube Origin;
            // GenerateIT goes through yt.fetch, which wants YouTube's.
            return youtubeOriginForApi ? impersonate("https://www.youtube.com", xOrigin: false) : [:]
        }
        if host == "s.youtube.com" {
            return impersonate("https://music.youtube.com", xOrigin: false)
        }
        if host.hasSuffix("googlevideo.com") {
            // VISIONOS URLs go with no Origin or Referer at all (rule 7).
            if query.contains("c=VISIONOS") { return [:] }
            return impersonate("https://www.youtube.com", xOrigin: false)
        }
        if host == "amp-api.music.apple.com" {
            return impersonate("https://music.apple.com", xOrigin: false)
        }
        if host.hasSuffix("musixmatch.com") {
            return ["Cookie": "mxm_bab=AB"]
        }
        return [:]
    }

    static func upstreamRequest(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        youtubeOriginForApi: Bool = false
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        for (key, value) in headers where !dropped.contains(key.lowercased()) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        for (key, value) in extraHeaders(for: url, youtubeOriginForApi: youtubeOriginForApi) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body, method != "GET", method != "HEAD" {
            request.httpBody = body
        }
        return request
    }

    /// Response headers as the page should see them: URLSession has already
    /// decoded the body, so the encoding and length no longer apply, and CORS is open.
    static func pageHeaders(from response: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        let encoded = response.value(forHTTPHeaderField: "Content-Encoding").map { !$0.isEmpty && $0 != "identity" } ?? false
        for (k, v) in response.allHeaderFields {
            guard let key = k as? String, let value = v as? String else { continue }
            let lower = key.lowercased()
            if lower == "content-encoding" || (encoded && lower == "content-length") || lower == "transfer-encoding"
                || lower.hasPrefix("access-control-") || lower == "set-cookie"
            {
                continue
            }
            out[key] = value
        }
        out["Access-Control-Allow-Origin"] = "*"
        out["Access-Control-Expose-Headers"] = "*"
        out["X-BitChord-Final-Url"] = response.url?.absoluteString ?? ""
        return out
    }
}
