import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves `app://bitchord/…`:
/// - `/__net/?u=<url>`: a streaming proxy for the page's cross-origin GETs
///   (InnerTube, googlevideo audio, lyrics…), with NetRules' headers applied.
///   Same origin as the page, so no CORS check ever runs.
/// - anything else: the built web app bundled at `www/`, with index.html as
///   the fallback for client-side routes.
final class AppSchemeHandler: NSObject, WKURLSchemeHandler, URLSessionDataDelegate {
    static let scheme = "app"
    static let host = "bitchord"
    static let origin = "\(scheme)://\(host)"

    private let root: URL = Bundle.main.resourceURL!.appendingPathComponent("www", isDirectory: true)

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    /// Live proxy tasks. Everything runs on the main queue, so no lock is needed.
    private var byTask: [Int: WKURLSchemeTask] = [:]
    private var stopped = Set<ObjectIdentifier>()
    private var dataTaskFor: [ObjectIdentifier: URLSessionDataTask] = [:]
    /// Scheme tasks answered by MediaCache (whole-file audio).
    private var cachedTasks = Set<ObjectIdentifier>()
    /// Bytes received per proxy task, for the debug log.
    private var received: [Int: Int] = [:]

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        // URL.path drops the trailing slash: "/__net/?u=…" arrives as "/__net".
        if url.path.hasPrefix("/__local/") {
            let videoId = String(url.path.dropFirst("/__local/".count)).removingPercentEncoding ?? ""
            let file = MainActor.assumeIsolated { OfflineStore.shared.fileURL(videoId) }
            if let file {
                serveFile(urlSchemeTask, url: url, file: file, contentType: "audio/mp4")
            } else {
                respond(urlSchemeTask, url: url, status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not saved".utf8))
            }
            return
        }
        if url.path == "/__net" || url.path.hasPrefix("/__net/") {
            startProxy(urlSchemeTask, url: url)
        } else {
            serveFile(urlSchemeTask, url: url)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        if cachedTasks.remove(id) != nil {
            MainActor.assumeIsolated { MediaCache.shared.stop(urlSchemeTask) }
            return
        }
        stopped.insert(id)
        if let task = dataTaskFor.removeValue(forKey: id) {
            byTask.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
    }

    // MARK: Static files

    /// A file on the phone (a saved track), with byte ranges for the player.
    private func serveFile(_ task: WKURLSchemeTask, url: URL, file: URL, contentType: String) {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            respond(task, url: url, status: 500, headers: ["Content-Type": "text/plain"], body: Data())
            return
        }
        var headers = ["Content-Type": contentType, "Accept-Ranges": "bytes", "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"]
        if let range = task.request.value(forHTTPHeaderField: "Range"), let r = Self.parseRange(range, length: data.count) {
            headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(data.count)"
            headers["Content-Length"] = String(r.count)
            respond(task, url: url, status: 206, headers: headers, body: data.subdata(in: r))
            return
        }
        headers["Content-Length"] = String(data.count)
        respond(task, url: url, status: 200, headers: headers, body: data)
    }

    private func serveFile(_ task: WKURLSchemeTask, url: URL) {
        var path = url.path.removingPercentEncoding ?? url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        var file = root.appendingPathComponent(String(path.dropFirst()))
        // Never serve outside www/.
        if !file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path) {
            file = root.appendingPathComponent("index.html")
        }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) || isDir.boolValue {
            // Client-side routes (/search, /album/…) all load the app shell.
            if file.pathExtension.isEmpty || isDir.boolValue {
                file = root.appendingPathComponent("index.html")
            } else {
                respond(task, url: url, status: 404, headers: ["Content-Type": "text/plain"], body: Data("Not found".utf8))
                return
            }
        }
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else {
            respond(task, url: url, status: 500, headers: ["Content-Type": "text/plain"], body: Data())
            return
        }
        var headers = [
            "Content-Type": Self.mimeType(for: file),
            "Cache-Control": "no-cache",
            "Access-Control-Allow-Origin": "*",
        ]

        // Byte ranges, for media files the app may play from its own bundle.
        if let range = task.request.value(forHTTPHeaderField: "Range"), let r = Self.parseRange(range, length: data.count) {
            headers["Content-Range"] = "bytes \(r.lowerBound)-\(r.upperBound - 1)/\(data.count)"
            headers["Accept-Ranges"] = "bytes"
            respond(task, url: url, status: 206, headers: headers, body: data.subdata(in: r))
            return
        }
        headers["Content-Length"] = String(data.count)
        respond(task, url: url, status: 200, headers: headers, body: data)
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, status: Int, headers: [String: String], body: Data) {
        guard !stopped.contains(ObjectIdentifier(task)) else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(body)
        task.didFinish()
    }

    static func parseRange(_ header: String, length: Int) -> Range<Int>? {
        guard header.hasPrefix("bytes="), length > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int(parts[1]) {
            return max(0, length - suffix)..<length
        }
        guard let start = Int(parts[0]), start < length else { return nil }
        let end = parts[1].isEmpty ? length - 1 : min(Int(parts[1]) ?? (length - 1), length - 1)
        return start..<(end + 1)
    }

    static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "txt": return "text/plain; charset=utf-8"
        default:
            return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    // MARK: Proxy

    private func startProxy(_ task: WKURLSchemeTask, url: URL) {
        guard
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let target = comps.queryItems?.first(where: { $0.name == "u" })?.value,
            let upstream = URL(string: target),
            let scheme = upstream.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else {
            respond(task, url: url, status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad proxy URL".utf8))
            return
        }
        let incoming = task.request
        if (incoming.httpMethod ?? "GET") == "GET", MediaCache.handles(upstream) {
            cachedTasks.insert(ObjectIdentifier(task))
            MainActor.assumeIsolated { MediaCache.shared.start(task, pageURL: url, upstream: upstream) }
            return
        }
        var body = incoming.httpBody
        if body == nil, let stream = incoming.httpBodyStream { body = Self.read(stream) }
        let request = NetRules.upstreamRequest(
            url: upstream,
            method: incoming.httpMethod ?? "GET",
            headers: incoming.allHTTPHeaderFields ?? [:],
            body: body
        )
        let dataTask = session.dataTask(with: request)
        byTask[dataTask.taskIdentifier] = task
        dataTaskFor[ObjectIdentifier(task)] = dataTask
        dataTask.resume()
    }

    /// Host, path and the query keys that tell streams apart, for the log (never full signed URLs).
    static func short(_ url: URL?) -> String {
        guard let url, let host = url.host else { return "?" }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let keep = q.filter { ["itag", "c", "clen", "range"].contains($0.name) }.map { "\($0.name)=\($0.value ?? "")" }
        return "\(host)\(url.path)" + (keep.isEmpty ? "" : "?" + keep.joined(separator: "&"))
    }

    static func read(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        let size = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: size)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private func live(_ dataTask: URLSessionTask) -> WKURLSchemeTask? {
        guard let task = byTask[dataTask.taskIdentifier], !stopped.contains(ObjectIdentifier(task)) else { return nil }
        return task
    }

    private func finish(_ dataTask: URLSessionTask) {
        if let task = byTask.removeValue(forKey: dataTask.taskIdentifier) {
            dataTaskFor.removeValue(forKey: ObjectIdentifier(task))
            stopped.remove(ObjectIdentifier(task))
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let task = live(dataTask), let http = response as? HTTPURLResponse, let url = task.request.url else {
            completionHandler(.cancel)
            return
        }
        let pageResponse = HTTPURLResponse(
            url: url,
            statusCode: http.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: NetRules.pageHeaders(from: http)
        )!
        if WebViewController.diagnostics { NSLog("[BitChord][net] %d %@ %@ enc=%@ type=%@", http.statusCode, dataTask.originalRequest?.httpMethod ?? "?",
              String((dataTask.originalRequest?.url?.absoluteString ?? "").prefix(110)),
              http.value(forHTTPHeaderField: "Content-Encoding") ?? "-", http.value(forHTTPHeaderField: "Content-Type") ?? "-") }
        if http.statusCode >= 400 {
            Diag.log("net \(http.statusCode) \(dataTask.originalRequest?.httpMethod ?? "?") \(Self.short(dataTask.originalRequest?.url))")
        }
        task.didReceive(pageResponse)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received[dataTask.taskIdentifier, default: 0] += data.count
        live(dataTask)?.didReceive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let bytes = received.removeValue(forKey: task.taskIdentifier) ?? 0
        if WebViewController.diagnostics && (error != nil || bytes < 200_000) {
            NSLog("[BitChord][net] done %@ bytes=%d err=%@", String((task.originalRequest?.url?.absoluteString ?? "").prefix(90)), bytes, String(describing: error))
        }
        if let error, (error as? URLError)?.code != .cancelled {
            Diag.log("net error \(Self.short(task.originalRequest?.url)): \(error.localizedDescription)")
        }
        if let schemeTask = live(task) {
            if let error {
                schemeTask.didFailWithError(error)
            } else {
                schemeTask.didFinish()
            }
        }
        finish(task)
    }
}
