import CryptoKit
import Foundation
import WebKit

/// YouTube Music sign-in for the iOS app: the port of web/extension/lib/ytAuth.ts.
///
/// The Google session lives in the app's own cookie jar (WKWebsiteDataStore.default(),
/// filled by SignInViewController). Signed requests carry those cookies and a
/// SAPISIDHASH computed here; the page only ever learns names and pictures.
@MainActor
final class YouTubeAuth {
    static let shared = YouTubeAuth()

    static let musicOrigin = "https://music.youtube.com"
    private static let signingCookies = ["SAPISID", "__Secure-3PAPISID", "__Secure-1PAPISID"]
    private static let webRemixVersion = "1.20251006.03.00"
    /// X-Goog-AuthUser indices tried (Google allows ten logins; a phone rarely has more than a few).
    private static let maxLogins = 5
    private static let accountsTTL: TimeInterval = 600

    struct Channel {
        let id: String
        let name: String
        let handle: String?
        let avatarUrl: String?
        let brand: Bool
        let authUser: String
        let pageId: String?
        let selectedOnWeb: Bool

        var publicJSON: [String: Any] {
            ["id": id, "name": name, "handle": handle ?? NSNull(), "avatarUrl": avatarUrl ?? NSNull(), "brand": brand]
        }
    }

    struct Account {
        let authUser: String
        let name: String
        let email: String?
        let avatarUrl: String?
        let channels: [Channel]
    }

    struct Identity {
        let authUser: String
        let pageId: String?
    }

    struct SignedOut: LocalizedError {
        var errorDescription: String? { "Not signed in to YouTube Music." }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private var cache: (list: [Account], webIndex: String?, at: Date)?
    /// DATASYNC_ID per channel: what a signed-in session's PO tokens are bound to.
    private var dataSyncIds: [String: String] = [:]
    private var reading: Task<(list: [Account], webIndex: String?), Never>?
    private var problem: String?

    // MARK: Preferences

    private let defaults = UserDefaults.standard
    private var connected: Bool {
        get { defaults.object(forKey: "yt.connected") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "yt.connected") }
    }
    private var selectedChannelId: String? {
        get { defaults.string(forKey: "yt.selectedChannelId") }
        set { defaults.set(newValue, forKey: "yt.selectedChannelId") }
    }

    func invalidate() {
        cache = nil
        dataSyncIds.removeAll()
    }

    // MARK: Cookies and signing

    private func cookies(for url: URL) async -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let now = Date()
        return all.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domainOK = host == domain || host.hasSuffix("." + domain)
            let pathOK = url.path.isEmpty || url.path.hasPrefix(cookie.path) || cookie.path == "/"
            let fresh = cookie.expiresDate.map { $0 > now } ?? true
            return domainOK && pathOK && fresh
        }
    }

    private func signingSecret() async -> String? {
        let jar = await cookies(for: URL(string: Self.musicOrigin + "/")!)
        for name in Self.signingCookies {
            if let value = jar.first(where: { $0.name == name })?.value, !value.isEmpty { return value }
        }
        return nil
    }

    var hasSession: Bool {
        get async { await signingSecret() != nil }
    }

    private static func sapisidHash(_ secret: String, origin: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(timestamp) \(secret) \(origin)".utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }

    /// A request made as `identity`, signed for `signAs` when that isn't the URL's own origin.
    func signedRequest(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        identity: Identity,
        signAs: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        guard let secret = await signingSecret() else { throw SignedOut() }
        let ownOrigin = "\(url.scheme ?? "https")://\(url.host ?? "")"
        let origin = signAs ?? ownOrigin
        var request = NetRules.upstreamRequest(url: url, method: method, headers: headers, body: body)
        // As the extension's own requests go: YouTube's Origin and Referer, the signature over it.
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        request.setValue(Self.sapisidHash(secret, origin: origin), forHTTPHeaderField: "Authorization")
        request.setValue(identity.authUser, forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue(identity.pageId, forHTTPHeaderField: "X-Goog-PageId")
        let jar = await cookies(for: url)
        if let cookieHeader = HTTPCookie.requestHeaderFields(with: jar)["Cookie"] {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await session.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    private func musicApi(_ endpoint: String, identity: Identity) async throws -> Any {
        let body: [String: Any] = [
            "context": [
                "client": ["clientName": "WEB_REMIX", "clientVersion": Self.webRemixVersion, "hl": "en", "gl": "US"],
                "user": [String: Any](),
            ],
        ]
        let (data, response) = try await signedRequest(
            url: URL(string: "\(Self.musicOrigin)/youtubei/v1/\(endpoint)?prettyPrint=false")!,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "X-Youtube-Client-Name": "67",
                "X-Youtube-Client-Version": Self.webRemixVersion,
            ],
            body: try JSONSerialization.data(withJSONObject: body),
            identity: identity
        )
        guard (200..<300).contains(response.statusCode) else {
            throw NSError(domain: "YouTubeAuth", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(response.statusCode)"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    // MARK: Reading the account renderers

    private static func renderers(_ root: Any, key: String, into out: inout [[String: Any]]) {
        if let array = root as? [Any] {
            for item in array { renderers(item, key: key, into: &out) }
        } else if let object = root as? [String: Any] {
            for (k, v) in object {
                if k == key, let found = v as? [String: Any] { out.append(found) } else { renderers(v, key: key, into: &out) }
            }
        }
    }

    private static func renderers(_ root: Any, key: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        renderers(root, key: key, into: &out)
        return out
    }

    private static func findString(_ root: Any, key: String) -> String? {
        if let array = root as? [Any] {
            for item in array { if let found = findString(item, key: key) { return found } }
        } else if let object = root as? [String: Any] {
            for (k, v) in object {
                if k == key, let s = v as? String, !s.isEmpty { return s }
                if let found = findString(v, key: key) { return found }
            }
        }
        return nil
    }

    private static func text(_ node: Any?) -> String {
        guard let node = node as? [String: Any] else { return "" }
        if let runs = node["runs"] as? [[String: Any]] { return runs.map { $0["text"] as? String ?? "" }.joined() }
        return node["simpleText"] as? String ?? ""
    }

    private static func photo(_ item: [String: Any]) -> String? {
        let thumbnails = (item["accountPhoto"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        return thumbnails?.last?["url"] as? String
    }

    private static func channelId(_ authUser: String, _ pageId: String?) -> String { "\(authUser):\(pageId ?? "own")" }

    private static func parseChannels(_ root: Any, authUser: String) -> [Channel] {
        var channels: [Channel] = []
        for item in renderers(root, key: "accountItem") {
            let name = text(item["accountName"])
            if name.isEmpty { continue }
            let pageId = findString(item, key: "pageId")
            let handle = [text(item["channelHandle"]), text(item["accountByline"])].first { !$0.isEmpty }
            let id = channelId(authUser, pageId)
            if channels.contains(where: { $0.id == id }) { continue }
            channels.append(Channel(
                id: id, name: name, handle: handle, avatarUrl: photo(item), brand: pageId != nil,
                authUser: authUser, pageId: pageId, selectedOnWeb: item["isSelected"] as? Bool == true
            ))
        }
        return channels
    }

    private func readLogin(_ authUser: String) async -> (account: Account?, why: String?) {
        let identity = Identity(authUser: authUser, pageId: nil)
        let header: [String: Any]
        do {
            let menu = try await musicApi("account/account_menu", identity: identity)
            guard let found = Self.renderers(menu, key: "activeAccountHeaderRenderer").first else {
                return (nil, "account_menu: YouTube answered as if signed out")
            }
            header = found
        } catch {
            return (nil, "account_menu: \(error.localizedDescription)")
        }
        let name = Self.text(header["accountName"]).isEmpty ? "YouTube Music" : Self.text(header["accountName"])
        let email = Self.text(header["email"]).isEmpty ? nil : Self.text(header["email"])
        let handle = Self.text(header["channelHandle"]).isEmpty ? nil : Self.text(header["channelHandle"])
        let avatar = Self.photo(header)
        var channels: [Channel] = []
        if let list = try? await musicApi("account/accounts_list", identity: identity) {
            channels = Self.parseChannels(list, authUser: authUser)
        }
        if channels.isEmpty {
            channels = [Channel(
                id: Self.channelId(authUser, nil), name: name, handle: handle ?? email, avatarUrl: avatar,
                brand: false, authUser: authUser, pageId: nil, selectedOnWeb: true
            )]
        }
        return (Account(authUser: authUser, name: name, email: email, avatarUrl: avatar, channels: channels), nil)
    }

    /// The login YouTube Music's own page uses (ytcfg SESSION_INDEX).
    private func webSessionIndex() async -> String? {
        guard let (data, _) = try? await signedRequest(
            url: URL(string: Self.musicOrigin + "/")!,
            headers: ["Accept": "text/html"],
            identity: Identity(authUser: "0", pageId: nil)
        ), let html = String(data: data, encoding: .utf8) else { return nil }
        guard let range = html.range(of: #""SESSION_INDEX":"?(\d+)"#, options: .regularExpression) else { return nil }
        return String(html[range].filter(\.isNumber))
    }

    private func readAccounts() async -> (list: [Account], webIndex: String?) {
        problem = nil
        async let webIndex = webSessionIndex()
        var results: [(Int, Account?, String?)] = []
        await withTaskGroup(of: (Int, Account?, String?).self) { group in
            for i in 0..<Self.maxLogins {
                group.addTask { @MainActor in
                    let r = await self.readLogin(String(i))
                    return (i, r.account, r.why)
                }
            }
            for await r in group { results.append(r) }
        }
        results.sort { $0.0 < $1.0 }
        let index = await webIndex
        var list: [Account] = []
        var seen = Set<String>()
        for (_, account, _) in results {
            guard let account else { continue }
            let key = account.email ?? "\(account.name)|\(account.channels.map(\.id).joined(separator: ","))"
            if seen.insert(key).inserted { list.append(account) }
        }
        if list.isEmpty {
            let i = Int(index ?? "0") ?? 0
            problem = results.first { $0.0 == i }?.2 ?? results.first?.2 ?? "no signed-in Google account found"
        }
        return (list, index)
    }

    private func accounts(refresh: Bool) async -> (list: [Account], webIndex: String?) {
        if !refresh, let cache, Date().timeIntervalSince(cache.at) < Self.accountsTTL { return (cache.list, cache.webIndex) }
        if let reading { return await reading.value }
        let task = Task { await self.readAccounts() }
        reading = task
        let read = await task.value
        reading = nil
        cache = (read.list, read.webIndex, Date())
        return read
    }

    private func chooseChannel(_ read: (list: [Account], webIndex: String?)) -> Channel? {
        let all = read.list.flatMap(\.channels)
        let web = read.list.first { $0.authUser == read.webIndex } ?? read.list.first
        return all.first { $0.id == selectedChannelId }
            ?? web?.channels.first { $0.selectedOnWeb }
            ?? web?.channels.first
    }

    /// The account's DATASYNC_ID (ytcfg on YouTube Music's page, signed in as [channel]):
    /// its first part is what YouTube binds a signed-in session's PO tokens to.
    private func dataSyncId(for channel: Channel) async -> String? {
        if let known = dataSyncIds[channel.id] { return known }
        guard let (data, _) = try? await signedRequest(
            url: URL(string: Self.musicOrigin + "/")!,
            headers: ["Accept": "text/html"],
            identity: Identity(authUser: channel.authUser, pageId: channel.pageId)
        ), let html = String(data: data, encoding: .utf8),
            let range = html.range(of: #""DATASYNC_ID":"[^"]*""#, options: .regularExpression)
        else {
            Diag.log("no DATASYNC_ID on YouTube Music's page")
            return nil
        }
        // The separator may come escaped inside the page's JSON (backslash-u007c).
        let raw = String(html[range].dropFirst("\"DATASYNC_ID\":\"".count).dropLast())
            .replacingOccurrences(of: #"\u007c"#, with: "|")
        let id = String(raw.split(separator: "|", omittingEmptySubsequences: true).first ?? "")
        guard !id.isEmpty else { return nil }
        dataSyncIds[channel.id] = id
        return id
    }

    // MARK: Bridge methods

    func authState(refresh: Bool = false) async -> [String: Any] {
        let browserSignedIn = await hasSession
        guard browserSignedIn, connected else {
            return ["browserSignedIn": browserSignedIn, "connected": connected, "signedIn": false,
                    "accounts": [Any](), "active": NSNull(), "problem": NSNull()]
        }
        let read = await accounts(refresh: refresh)
        let active = chooseChannel(read)
        let problemJSON: Any = active == nil ? (problem.map { $0 as Any } ?? NSNull()) : NSNull()
        var syncJSON: Any = NSNull()
        if let active, let id = await dataSyncId(for: active) { syncJSON = id }
        var activeJSON: Any = NSNull()
        if let active {
            var json = active.publicJSON
            json["authUser"] = active.authUser
            activeJSON = json
        }
        return [
            "browserSignedIn": true,
            "connected": true,
            "signedIn": active != nil,
            "problem": problemJSON,
            "accounts": read.list.map { account -> [String: Any] in
                ["authUser": account.authUser, "name": account.name, "email": account.email ?? NSNull(),
                 "avatarUrl": account.avatarUrl ?? NSNull(), "channels": account.channels.map(\.publicJSON)]
            },
            "active": activeJSON,
            // Not in the extension's contract: the iOS page binds signed-in PO tokens to it.
            "dataSyncId": syncJSON,
        ]
    }

    func activeIdentity() async -> Identity? {
        guard connected, await hasSession else { return nil }
        guard let active = chooseChannel(await accounts(refresh: false)) else { return nil }
        return Identity(authUser: active.authUser, pageId: active.pageId)
    }

    func selectChannel(_ id: String) async throws -> [String: Any] {
        let read = await accounts(refresh: false)
        guard read.list.contains(where: { $0.channels.contains { $0.id == id } }) else {
            throw NSError(domain: "YouTubeAuth", code: 1, userInfo: [NSLocalizedDescriptionKey: "No channel \(id)"])
        }
        selectedChannelId = id
        return await authState()
    }

    func setConnected(_ value: Bool) async -> [String: Any] {
        connected = value
        return await authState(refresh: value)
    }

    /// Signs out of Google in this app: forgets its cookies.
    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let google = records.filter { $0.displayName.contains("google") || $0.displayName.contains("youtube") }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: google)
        invalidate()
    }

    private static let stats = try! NSRegularExpression(pattern: #"^https://(s|music|www)\.youtube\.com/api/stats/(playback|watchtime|atr)(\?|$)"#)
    private static let allowedSigned = try! NSRegularExpression(pattern: #"^https://(music|www)\.youtube\.com/youtubei/v1/"#)
    private static let identityHeaders: Set<String> = ["authorization", "cookie", "x-goog-authuser", "x-goog-pageid", "x-origin", "origin", "referer"]

    /// `yt.fetch` with `auth: true` (ytFetch.ts signedYtFetch).
    func signedYtFetch(_ params: [String: Any]) async throws -> [String: Any] {
        let urlString = params["url"] as? String ?? ""
        let method = (params["method"] as? String ?? "GET").uppercased()
        let whole = NSRange(urlString.startIndex..., in: urlString)
        let isStats = Self.stats.firstMatch(in: urlString, range: whole) != nil && method == "GET"
        guard isStats || Self.allowedSigned.firstMatch(in: urlString, range: whole) != nil, let url = URL(string: urlString) else {
            throw NSError(domain: "YouTubeAuth", code: 403, userInfo: [NSLocalizedDescriptionKey: "yt.fetch doesn't serve \(urlString)"])
        }
        guard let identity = await activeIdentity() else { throw SignedOut() }
        var headers: [String: String] = [:]
        for (k, v) in params["headers"] as? [String: String] ?? [:] where !Self.identityHeaders.contains(k.lowercased()) {
            headers[k] = v
        }
        var body: Data?
        if let text = params["body"] as? String {
            body = (params["bodyEncoding"] as? String) == "base64" ? Data(base64Encoded: text) : Data(text.utf8)
        }
        let (data, response) = try await signedRequest(
            url: url, method: method, headers: headers, body: body, identity: identity,
            signAs: isStats ? Self.musicOrigin : nil
        )
        return Bridge.serialise(data: data, response: response, fallbackURL: urlString)
    }
}
