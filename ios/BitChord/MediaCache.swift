import Foundation
import WebKit

/// Whole-file audio cache for the native player (iOS app).
///
/// The audio element asks for byte ranges, again and again, as AVFoundation
/// buffers and seeks. Instead of passing each one to googlevideo, the first
/// request starts downloading the whole file in large sequential chunks (an
/// AAC track is a few megabytes, so it is in memory within seconds), and every
/// range is answered from memory as the bytes arrive. Once it's in, the track
/// can't be cut off mid-way and seeking is instant.
@MainActor
final class MediaCache {
    static let shared = MediaCache()

    /// Only audio streams: music videos are far larger and stream through Shaka.
    nonisolated static func handles(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host.hasSuffix("googlevideo.com"), url.path.hasPrefix("/videoplayback") else { return false }
        let mime = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "mime" }?.value ?? ""
        return mime.hasPrefix("audio")
    }

    private final class Waiter {
        let task: WKURLSchemeTask
        let url: URL
        let ranged: Bool
        let start: Int
        var end: Int? // inclusive; nil = to the end of the file
        var offset: Int
        var responded = false
        init(task: WKURLSchemeTask, url: URL, ranged: Bool, start: Int, end: Int?) {
            self.task = task
            self.url = url
            self.ranged = ranged
            self.start = start
            self.end = end
            offset = start
        }
    }

    private final class Entry {
        let key: String
        let upstream: URL
        var data = Data()
        var total: Int?
        var contentType = "audio/mp4"
        var finished = false
        var failure: (status: Int, message: String)?
        var waiters: [Waiter] = []
        var lastUsed = Date()
        var downloading = false
        init(key: String, upstream: URL) {
            self.key = key
            self.upstream = upstream
        }
    }

    private var entries: [String: Entry] = [:]
    private var waiterEntry: [ObjectIdentifier: Entry] = [:]
    private let firstChunk = 512 * 1024
    private let chunk = 3 * 1024 * 1024
    private let maxEntries = 4

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    private static func key(for url: URL) -> String {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        comps?.queryItems = comps?.queryItems?.filter { $0.name != "range" && $0.name != "rn" && $0.name != "rbuf" }
        return comps?.url?.absoluteString ?? url.absoluteString
    }

    // MARK: Scheme tasks

    func start(_ task: WKURLSchemeTask, pageURL: URL, upstream: URL) {
        let key = Self.key(for: upstream)
        let entry = entries[key] ?? {
            let made = Entry(key: key, upstream: upstream)
            entries[key] = made
            evict()
            if let clen = URLComponents(url: upstream, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "clen" })?.value {
                made.total = Int(clen)
            }
            return made
        }()
        entry.lastUsed = Date()

        var start = 0
        var end: Int?
        var ranged = false
        if let header = task.request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") {
            let spec = header.dropFirst(6).split(separator: ",").first ?? ""
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 2, let s = Int(parts[0]) {
                start = s
                end = Int(parts[1])
                ranged = true
            }
        }
        let waiter = Waiter(task: task, url: pageURL, ranged: ranged, start: start, end: end)
        entry.waiters.append(waiter)
        waiterEntry[ObjectIdentifier(task)] = entry
        if !entry.downloading && !entry.finished && entry.failure == nil { download(entry) }
        pump(entry)
    }

    func stop(_ task: WKURLSchemeTask) {
        guard let entry = waiterEntry.removeValue(forKey: ObjectIdentifier(task)) else { return }
        entry.waiters.removeAll { $0.task === task }
        // The download goes on: the player will be back for the rest.
    }

    // MARK: Download

    private func download(_ entry: Entry) {
        entry.downloading = true
        Task { [weak self] in
            await self?.run(entry)
        }
    }

    private func run(_ entry: Entry) async {
        var attempts = 0
        while !entry.finished {
            let from = entry.data.count
            let size = from == 0 ? firstChunk : chunk
            var to = from + size - 1
            if let total = entry.total { to = min(to, total - 1) }
            if let total = entry.total, from >= total {
                entry.finished = true
                break
            }
            var request = NetRules.upstreamRequest(url: entry.upstream, method: "GET", headers: [:], body: nil)
            request.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard http.statusCode == 206 || http.statusCode == 200 else {
                    attempts += 1
                    Diag.log("audio cache \(http.statusCode) at byte \(from) of \(entry.total.map(String.init) ?? "?") \(AppSchemeHandler.short(entry.upstream))")
                    if attempts >= 2 {
                        entry.failure = (http.statusCode, "HTTP \(http.statusCode)")
                        break
                    }
                    continue
                }
                attempts = 0
                if let type = http.value(forHTTPHeaderField: "Content-Type") { entry.contentType = type }
                if let range = http.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/"),
                   let total = Int(range[range.index(after: slash)...])
                {
                    entry.total = total
                } else if http.statusCode == 200 {
                    entry.total = data.count
                }
                if http.statusCode == 200 { entry.data = data } else { entry.data.append(data) }
                if data.isEmpty || (entry.total.map { entry.data.count >= $0 } ?? false) { entry.finished = true }
                pump(entry)
            } catch {
                attempts += 1
                Diag.log("audio cache error at byte \(from): \(error.localizedDescription)")
                if attempts >= 3 {
                    entry.failure = (502, error.localizedDescription)
                    break
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        entry.downloading = false
        if entry.finished { Diag.log("audio cache: whole track in memory (\(entry.data.count) bytes)") }
        pump(entry)
    }

    // MARK: Serving

    private func pump(_ entry: Entry) {
        for waiter in entry.waiters {
            serve(waiter, from: entry)
        }
        entry.waiters.removeAll { waiter in
            let done = waiter.offset > (waiter.end ?? Int.max) || (entry.total.map { waiter.offset >= $0 } ?? false)
            if done || (entry.failure != nil) { waiterEntry.removeValue(forKey: ObjectIdentifier(waiter.task)) }
            return done || entry.failure != nil
        }
    }

    private func serve(_ waiter: Waiter, from entry: Entry) {
        if let failure = entry.failure {
            if !waiter.responded {
                let response = HTTPURLResponse(url: waiter.url, statusCode: failure.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
                waiter.task.didReceive(response)
                waiter.task.didReceive(Data(failure.message.utf8))
                waiter.task.didFinish()
            } else {
                waiter.task.didFailWithError(URLError(.networkConnectionLost))
            }
            waiter.offset = Int.max
            return
        }
        // The answer's headers need the file's length.
        guard let total = entry.total else { return }
        if waiter.end == nil || waiter.end! >= total { waiter.end = total - 1 }
        let end = waiter.end!
        if !waiter.responded {
            guard waiter.start < total else {
                let response = HTTPURLResponse(url: waiter.url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes */\(total)"])!
                waiter.task.didReceive(response)
                waiter.task.didFinish()
                waiter.offset = Int.max
                return
            }
            var headers = [
                "Content-Type": entry.contentType,
                "Accept-Ranges": "bytes",
                "Content-Length": String(end - waiter.start + 1),
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-store",
            ]
            if waiter.ranged { headers["Content-Range"] = "bytes \(waiter.start)-\(end)/\(total)" }
            let response = HTTPURLResponse(url: waiter.url, statusCode: waiter.ranged ? 206 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            waiter.task.didReceive(response)
            waiter.responded = true
        }
        let available = entry.data.count
        guard waiter.offset < available else { return }
        let upTo = min(end + 1, available)
        if upTo > waiter.offset {
            waiter.task.didReceive(entry.data.subdata(in: waiter.offset..<upTo))
            waiter.offset = upTo
        }
        if waiter.offset > end {
            waiter.task.didFinish()
        }
    }

    private func evict() {
        guard entries.count > maxEntries else { return }
        let busy = Set(waiterEntry.values.map { $0.key })
        for entry in entries.values.sorted(by: { $0.lastUsed < $1.lastUsed }) where entries.count > maxEntries {
            if busy.contains(entry.key) || entry.downloading { continue }
            entries.removeValue(forKey: entry.key)
        }
    }
}
