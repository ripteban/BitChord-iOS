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

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        if url.path.hasPrefix("/__net/") {
            startProxy(urlSchemeTask, url: url)
        } else {
            serveFile(urlSchemeTask, url: url)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        stopped.insert(id)
        if let task = dataTaskFor.removeValue(forKey: id) {
            byTask.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
    }

    // MARK: Static files

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
        task.didReceive(pageResponse)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        live(dataTask)?.didReceive(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
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
