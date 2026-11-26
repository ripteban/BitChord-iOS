import Foundation

/// Tracks saved on the phone (web/app/src/playback/offline.ts):
/// - downloaded (kept for good): Documents/Offline, backed up like the user's files;
/// - cached (temporary): Caches/Offline, which iOS may clear when space runs short,
///   and which this store keeps under a size limit, oldest first.
/// One index (Documents/Offline/index.json) lists both.
@MainActor
final class OfflineStore {
    static let shared = OfflineStore()

    struct Entry: Codable {
        var videoId: String
        var title: String
        var artist: String
        var album: String?
        var artworkUrl: String?
        var durationSec: Double
        var permanent: Bool
        var bytes: Int
        var savedAt: Double

        var json: [String: Any] {
            [
                "videoId": videoId, "title": title, "artist": artist,
                "album": album ?? NSNull(), "artworkUrl": artworkUrl ?? NSNull(),
                "durationSec": durationSec, "permanent": permanent, "bytes": bytes, "savedAt": savedAt,
            ]
        }
    }

    /// Temporary cache ceiling: about 150 songs.
    private let cacheLimitBytes = 600 * 1024 * 1024
    private var entries: [String: Entry] = [:]
    private let fm = FileManager.default

    private lazy var documentsDir: URL = {
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Offline", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private lazy var cacheDir: URL = {
        let dir = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Offline", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var indexURL: URL { documentsDir.appendingPathComponent("index.json") }

    private init() {
        if let data = try? Data(contentsOf: indexURL), let list = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in list where fm.fileExists(atPath: file(for: entry).path) {
                entries[entry.videoId] = entry
            }
        }
    }

    private static func safe(_ videoId: String) -> String {
        String(videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }.prefix(64))
    }

    private func file(for entry: Entry) -> URL {
        (entry.permanent ? documentsDir : cacheDir).appendingPathComponent("\(Self.safe(entry.videoId)).m4a")
    }

    /// The file for [videoId], if it is on the phone.
    func fileURL(_ videoId: String) -> URL? {
        guard let entry = entries[videoId] else { return nil }
        let url = file(for: entry)
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(entries.values)) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    var list: [[String: Any]] {
        entries.values.filter { fm.fileExists(atPath: file(for: $0).path) }.map(\.json)
    }

    func save(videoId: String, data: Data, permanent: Bool, meta: [String: Any]) throws -> [String: Any] {
        var entry = Entry(
            videoId: videoId,
            title: meta["title"] as? String ?? "",
            artist: meta["artist"] as? String ?? "",
            album: meta["album"] as? String,
            artworkUrl: meta["artworkUrl"] as? String,
            durationSec: (meta["durationSec"] as? NSNumber)?.doubleValue ?? 0,
            permanent: permanent,
            bytes: data.count,
            savedAt: Date().timeIntervalSince1970 * 1000
        )
        if let old = entries[videoId] { try? fm.removeItem(at: file(for: old)) }
        try data.write(to: file(for: entry), options: .atomic)
        entry.bytes = data.count
        entries[videoId] = entry
        if !permanent { trimCache() }
        persist()
        Diag.log("offline: \(permanent ? "downloaded" : "cached") \(videoId) (\(data.count / 1024) KB)")
        return entry.json
    }

    // MARK: Saving in pieces (begin, append…, commit), so no single message holds the whole file

    private var partial: [String: URL] = [:]

    func begin(_ videoId: String) {
        let url = cacheDir.appendingPathComponent("\(Self.safe(videoId)).part")
        try? fm.removeItem(at: url)
        fm.createFile(atPath: url.path, contents: nil)
        partial[videoId] = url
    }

    func append(_ videoId: String, _ data: Data) throws {
        guard let url = partial[videoId], let handle = try? FileHandle(forWritingTo: url) else {
            throw NSError(domain: "Offline", code: 1, userInfo: [NSLocalizedDescriptionKey: "no save in progress"])
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func commit(videoId: String, permanent: Bool, meta: [String: Any]) throws -> [String: Any] {
        guard let part = partial.removeValue(forKey: videoId) else {
            throw NSError(domain: "Offline", code: 1, userInfo: [NSLocalizedDescriptionKey: "no save in progress"])
        }
        let bytes = (try? fm.attributesOfItem(atPath: part.path)[.size] as? Int) ?? 0
        guard bytes > 0 else { throw NSError(domain: "Offline", code: 2, userInfo: [NSLocalizedDescriptionKey: "empty file"]) }
        var entry = Entry(
            videoId: videoId,
            title: meta["title"] as? String ?? "",
            artist: meta["artist"] as? String ?? "",
            album: meta["album"] as? String,
            artworkUrl: meta["artworkUrl"] as? String,
            durationSec: (meta["durationSec"] as? NSNumber)?.doubleValue ?? 0,
            permanent: permanent,
            bytes: bytes,
            savedAt: Date().timeIntervalSince1970 * 1000
        )
        if let old = entries[videoId] { try? fm.removeItem(at: file(for: old)) }
        let target = file(for: entry)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: part, to: target)
        entry.bytes = bytes
        entries[videoId] = entry
        if !permanent { trimCache() }
        persist()
        Diag.log("offline: \(permanent ? "downloaded" : "cached") \(videoId) (\(bytes / 1024) KB)")
        return entry.json
    }

    /// A cached track kept for good: moved out of Caches.
    func pin(_ videoId: String) throws -> [String: Any] {
        guard var entry = entries[videoId] else { throw NSError(domain: "Offline", code: 404, userInfo: [NSLocalizedDescriptionKey: "not saved"]) }
        if !entry.permanent {
            let from = file(for: entry)
            entry.permanent = true
            let to = file(for: entry)
            try? fm.removeItem(at: to)
            try fm.moveItem(at: from, to: to)
            entries[videoId] = entry
            persist()
        }
        return entry.json
    }

    func remove(_ videoId: String) {
        if let entry = entries.removeValue(forKey: videoId) {
            try? fm.removeItem(at: file(for: entry))
            persist()
        }
    }

    private func trimCache() {
        var cached = entries.values.filter { !$0.permanent }.sorted { $0.savedAt < $1.savedAt }
        var total = cached.reduce(0) { $0 + $1.bytes }
        while total > cacheLimitBytes, let oldest = cached.first {
            cached.removeFirst()
            total -= oldest.bytes
            remove(oldest.videoId)
        }
    }
}
