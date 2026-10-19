import Foundation
import CryptoKit
import Security

enum CookieVault {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.majjcom.BiliDownloader.macOS", kSecAttrAccount as String: "bilibili-session"]
    static func load() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            throw BiliError.message("无法读取钥匙串中的登录信息（\(status)）。请解锁钥匙串后重试。")
        }
        return text
    }
    static func save(_ cookie: String) throws {
        if cookie.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw BiliError.message("无法删除钥匙串登录信息（\(status)）。") }
            return
        }
        let data = Data(cookie.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw BiliError.message("无法保存登录信息到钥匙串（\(added)）。") }
        } else if status != errSecSuccess { throw BiliError.message("无法更新钥匙串登录信息（\(status)）。") }
    }
}

enum WbiSigner {
    private static let table = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52]
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~"))!.replacingOccurrences(of: "%20", with: "+")
    }
    static func query(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { encode($0) + "=" + encode(parameters[$0]!) }.joined(separator: "&")
    }
    static func sign(_ parameters: [String: String], image: String, sub: String, timestamp: Int) throws -> [String: String] {
        let key = Array(image + sub)
        guard key.count >= 64 else { throw BiliError.message("B 站返回了无效的 WBI 签名密钥。") }
        let mixin = String(table.prefix(32).map { key[$0] })
        var params = parameters
        params["wts"] = String(timestamp)
        params = params.mapValues { $0.filter { !"!'()*".contains($0) } }
        let digest = Insecure.MD5.hash(data: Data((query(params) + mixin).utf8))
        params["w_rid"] = digest.map { String(format: "%02x", $0) }.joined()
        return params
    }
}

actor BiliAPI {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15"
    private let session: URLSession
    private var cookie = ""
    private var keys: (String, String)?
    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25
        self.session = session ?? URLSession(configuration: config)
    }
    func setCookie(_ value: String) { cookie = value; keys = nil }
    func cookieHeader() -> String { cookie }

    func request(_ endpoint: String, params: [String: String] = [:], allowGuest: Bool = false,
                 body: [String: Any]? = nil) async throws -> ([String: Any], HTTPURLResponse) {
        var components = URLComponents(string: endpoint)!
        if !params.isEmpty { components.percentEncodedQuery = WbiSigner.query(params) }
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        if !cookie.isEmpty { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BiliError.message("连接 B 站失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）。请稍后重试。")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BiliError.message("B 站响应格式无法识别。") }
        let code = json["code"] as? Int ?? -1
        guard code == 0 || (allowGuest && code == -101) else {
            throw BiliError.message("\(json["message"] as? String ?? json["msg"] as? String ?? "请求失败")（\(code)）")
        }
        return (json, http)
    }
    private func data(_ path: String, params: [String: String] = [:], result: String = "data") async throws -> [String: Any] {
        let (json, _) = try await request("https://api.bilibili.com" + path, params: params)
        guard let data = json[result] as? [String: Any] else { throw BiliError.message("未找到视频数据。") }
        return data
    }
    func resolve(_ input: String) async throws -> VideoInfo {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "https?://b23\\.tv/[a-zA-Z0-9]+", options: .regularExpression), let url = URL(string: String(text[range])) {
            // Only resolve the known short-link host; never forward session cookies.
            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let (_, response) = try await session.data(for: request)
            text = response.url?.absoluteString ?? text
        }
        let reference = try VideoReference.parse(text)
        switch reference {
        case .bv(let id): return try await video(params: ["bvid": id])
        case .av(let id): return try await video(params: ["aid": String(id)])
        case .ep(let id): return try await season(params: ["ep_id": String(id)])
        case .ss(let id): return try await season(params: ["season_id": String(id)])
        case .md(let id):
            let info = try await data("/pgc/review/user", params: ["media_id": String(id)], result: "result")
            guard let media = info["media"] as? [String: Any], let seasonID = media["season_id"] as? Int else { throw BiliError.message("未找到该番剧。") }
            return try await season(params: ["season_id": String(seasonID)])
        }
    }
    private func video(params: [String: String]) async throws -> VideoInfo {
        let raw = try await data("/x/web-interface/view", params: params)
        guard let aid = raw["aid"] as? Int, let bvid = raw["bvid"] as? String else { throw BiliError.message("视频编号无效。") }
        let pages = raw["pages"] as? [[String: Any]] ?? []
        let parts = pages.enumerated().compactMap { index, page -> VideoPart? in
            guard let cid = page["cid"] as? Int else { return nil }
            return .init(cid: cid, title: page["part"] as? String ?? "P\(index + 1)", index: index + 1,
                         duration: page["duration"] as? Int ?? 0, bvid: bvid, aid: aid)
        }
        guard !parts.isEmpty else { throw BiliError.message("此视频暂无可下载的分集。") }
        return .init(id: bvid, title: raw["title"] as? String ?? bvid,
                     author: (raw["owner"] as? [String: Any])?["name"] as? String ?? "哔哩哔哩",
                     cover: Self.imageURL(raw["pic"] as? String), description: raw["desc"] as? String ?? "", parts: parts)
    }
    private func season(params: [String: String]) async throws -> VideoInfo {
        let raw = try await data("/pgc/view/web/season", params: params, result: "result")
        let sid = raw["season_id"] as? Int ?? 0
        let episodes = raw["episodes"] as? [[String: Any]] ?? []
        let parts = episodes.enumerated().compactMap { index, ep -> VideoPart? in
            guard let cid = ep["cid"] as? Int, let eid = ep["id"] as? Int else { return nil }
            let title = [ep["title"] as? String, ep["long_title"] as? String].compactMap { $0 }.joined(separator: " · ")
            return .init(cid: cid, title: title, index: index + 1, duration: (ep["duration"] as? Int ?? 0) / 1000,
                         bvid: ep["bvid"] as? String ?? "", aid: ep["aid"] as? Int ?? 0, episodeID: eid, seasonID: sid)
        }
        guard !parts.isEmpty else { throw BiliError.message("此番剧暂无可下载的分集。") }
        return .init(id: "ss\(sid)", title: raw["title"] as? String ?? "番剧", author: "哔哩哔哩番剧",
                     cover: Self.imageURL(raw["cover"] as? String), description: raw["evaluate"] as? String ?? "", parts: parts)
    }
    static func imageURL(_ text: String?) -> URL? {
        guard let text else { return nil }
        return URL(string: text.hasPrefix("//") ? "https:" + text : text.replacingOccurrences(of: "http://", with: "https://"))
    }
    func playback(_ part: VideoPart, quality: Int = 127) async throws -> Playback {
        if let eid = part.episodeID, let sid = part.seasonID {
            var params: [String: String] = [:]
            if let token = cookie.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix("bili_jct=") }) {
                params["csrf"] = String(token.dropFirst(9))
            }
            let body: [String: Any] = ["exp_info": ["ogv_half_pay": true], "player_param": ["drm_tech_type": 2, "fnval": 4048, "fnver": 0],
                "scene": "normal", "video_index": ["ogv_episode_id": eid, "ogv_season_id": sid], "video_param": ["qn": quality]]
            do {
                let (json, _) = try await request("https://api.bilibili.com/ogv/player/playview", params: params, body: body)
                return try Playback.parse(json["data"] as? [String: Any] ?? [:])
            } catch {
                if Task.isCancelled { throw CancellationError() }
                let raw = try await data("/pgc/player/web/v2/playurl", params: ["avid": String(part.aid), "cid": String(part.cid), "ep_id": String(eid), "qn": String(quality), "fnval": "4048", "fourk": "1"], result: "result")
                return try Playback.parse(raw)
            }
        }
        if keys == nil {
            let (json, _) = try await request("https://api.bilibili.com/x/web-interface/nav", allowGuest: true)
            guard let nav = json["data"] as? [String: Any], let images = nav["wbi_img"] as? [String: Any],
                  let image = images["img_url"] as? String, let sub = images["sub_url"] as? String else { throw BiliError.message("无法获取 B 站签名信息。") }
            keys = (URL(string: image)!.deletingPathExtension().lastPathComponent, URL(string: sub)!.deletingPathExtension().lastPathComponent)
        }
        var params = ["cid": String(part.cid), "qn": String(quality), "fnval": "4048", "fourk": "1", "fnver": "0"]
        if part.bvid.isEmpty { params["avid"] = String(part.aid) } else { params["bvid"] = part.bvid }
        params = try WbiSigner.sign(params, image: keys!.0, sub: keys!.1, timestamp: Int(Date().timeIntervalSince1970))
        return try Playback.parse(await data("/x/player/wbi/playurl", params: params))
    }
    func account() async throws -> String? {
        let (json, _) = try await request("https://api.bilibili.com/x/web-interface/nav", allowGuest: true)
        let raw = json["data"] as? [String: Any] ?? [:]
        return raw["isLogin"] as? Bool == true ? raw["uname"] as? String : nil
    }
    func generateQR() async throws -> (String, String) {
        let (json, _) = try await request("https://passport.bilibili.com/x/passport-login/web/qrcode/generate")
        guard let raw = json["data"] as? [String: Any], let url = raw["url"] as? String, let key = raw["qrcode_key"] as? String else { throw BiliError.message("无法生成登录二维码。") }
        return (url, key)
    }
    func pollQR(_ key: String) async throws -> (Int, String?) {
        let (json, response) = try await request("https://passport.bilibili.com/x/passport-login/web/qrcode/poll", params: ["qrcode_key": key])
        guard let raw = json["data"] as? [String: Any], let code = raw["code"] as? Int else { throw BiliError.message("无法识别登录状态。") }
        guard code == 0 else { return (code, nil) }
        var cookies: [String: String] = [:]
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
        for item in HTTPCookie.cookies(withResponseHeaderFields: headers, for: response.url!) { cookies[item.name] = item.value }
        if let url = raw["url"] as? String, let components = URLComponents(string: url) {
            for item in components.queryItems ?? [] where ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"].contains(item.name) {
                if let value = item.value, cookies[item.name] == nil { cookies[item.name] = value }
            }
        }
        guard cookies["SESSDATA"] != nil else { throw BiliError.message("扫码成功，但未收到登录凭据，请刷新二维码重试。") }
        return (code, cookies.keys.sorted().map { $0 + "=" + cookies[$0]! }.joined(separator: "; "))
    }
    func danmaku(_ cid: Int) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://comment.bilibili.com/\(cid).xml")!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BiliError.message("获取弹幕失败。") }
        return data
    }
}
