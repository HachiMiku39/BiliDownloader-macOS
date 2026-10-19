import Foundation

enum BiliError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum VideoReference: Equatable {
    case bv(String), av(Int), ep(Int), md(Int), ss(Int)

    static func parse(_ text: String) throws -> VideoReference {
        let patterns = ["(?i)BV[a-z0-9]{10}(?![a-z0-9])", "(?i)(av|ep|md|ss)[0-9]+(?![a-z0-9])"]
        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                let value = String(text[range])
                let prefix = value.prefix(2).lowercased()
                if prefix == "bv" { return .bv("BV" + value.dropFirst(2)) }
                guard let id = Int(value.dropFirst(2)), id > 0 else { break }
                switch prefix {
                case "av": return .av(id)
                case "ep": return .ep(id)
                case "md": return .md(id)
                default: return .ss(id)
                }
            }
        }
        throw BiliError.message("未找到视频编号。请粘贴完整链接，或输入 BV、AV、EP、MD、SS 编号。")
    }
}

struct VideoPart: Codable, Identifiable, Hashable {
    var cid: Int
    var title: String
    var index: Int
    var duration: Int
    var bvid: String
    var aid: Int
    var episodeID: Int?
    var seasonID: Int?
    var id: Int { cid }
    var durationText: String { String(format: "%d:%02d", duration / 60, duration % 60) }
}

struct VideoInfo: Identifiable {
    var id: String
    var title: String
    var author: String
    var cover: URL?
    var description: String
    var parts: [VideoPart]
}

struct MediaStream: Equatable {
    var url: URL
    var quality: Int
    var codec: Int
    var bandwidth: Int
    var label: String
    static func parse(_ raw: [String: Any], label: String = "") -> MediaStream? {
        guard let path = raw["baseUrl"] as? String ?? raw["base_url"] as? String ?? raw["url"] as? String,
              let url = URL(string: path.hasPrefix("//") ? "https:" + path : path),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return .init(url: url, quality: raw["id"] as? Int ?? 0, codec: raw["codecid"] as? Int ?? 0,
                     bandwidth: raw["bandwidth"] as? Int ?? 0, label: label)
    }
}

struct Playback {
    var videos: [MediaStream]
    var audios: [MediaStream]
    var segments: [MediaStream]
    var qualityNames: [Int: String]
    var advertisedQualities: [Int]
    var preview: Bool

    static func parse(_ raw: [String: Any]) throws -> Playback {
        // Newer PGC responses nest the same DASH structure in video_info.
        let data = raw["video_info"] as? [String: Any] ?? raw
        let dash = data["dash"] as? [String: Any] ?? [:]
        let qualities = data["accept_quality"] as? [Int] ?? []
        let descriptions = data["accept_description"] as? [String] ?? []
        var names: [Int: String] = [:]
        var advertised = Set(qualities)
        for (key, value) in zip(qualities, descriptions) { names[key] = value }
        for item in data["support_formats"] as? [[String: Any]] ?? [] {
            if let quality = item["quality"] as? Int {
                advertised.insert(quality)
                if let name = item["new_description"] as? String ?? item["display_desc"] as? String { names[quality] = name }
            }
        }
        let videos = (dash["video"] as? [[String: Any]] ?? []).compactMap { MediaStream.parse($0) }
        var audios = (dash["audio"] as? [[String: Any]] ?? []).compactMap { MediaStream.parse($0, label: "标准") }
        if let flac = dash["flac"] as? [String: Any], let audio = flac["audio"] as? [String: Any], let stream = MediaStream.parse(audio, label: "FLAC") { audios.append(stream) }
        if let dolby = dash["dolby"] as? [String: Any] {
            audios += (dolby["audio"] as? [[String: Any]] ?? []).compactMap { MediaStream.parse($0, label: "Dolby") }
        }
        let segments = (data["durl"] as? [[String: Any]] ?? []).compactMap { MediaStream.parse($0) }
        guard !videos.isEmpty || !segments.isEmpty else {
            throw BiliError.message("没有可下载的视频流。该内容可能需要登录、购买，或暂不支持下载。")
        }
        return .init(videos: videos, audios: audios, segments: segments, qualityNames: names, advertisedQualities: advertised.sorted(by: >),
                     preview: (data["is_preview"] as? Int ?? 0) != 0 || (data["is_preview"] as? Bool ?? false))
    }

    var qualities: [Int] { Array(Set(videos.map(\.quality))).sorted(by: >) }
    // Like the upstream Windows menu, include the video's advertised formats.
    // Stream selection must still use only URLs actually returned by the API.
    var qualityOptions: [Int] { Array(Set(advertisedQualities + qualities)).sorted(by: >) }
    func preferredQuality(_ requested: Int) -> Int {
        qualityOptions.first(where: { $0 <= requested }) ?? qualityOptions.first ?? requested
    }
    func selectVideo(quality: Int, codec: Int) -> MediaStream? {
        let available = qualities
        let chosen = available.first(where: { $0 <= quality }) ?? available.last
        let matches = videos.filter { $0.quality == chosen }.sorted { $0.codec < $1.codec }
        return matches.first(where: { $0.codec == codec }) ?? matches.first
    }
    func selectAudio(preferred: String) -> MediaStream? {
        let matching = audios.filter { $0.label == preferred }
        return (matching.isEmpty ? audios.filter { $0.label == "标准" } : matching).max { $0.bandwidth < $1.bandwidth }
    }
    func qualityName(_ id: Int) -> String {
        qualityNames[id] ?? [127: "8K", 126: "Dolby Vision", 125: "HDR", 120: "4K 超清", 116: "1080P 60帧", 112: "1080P 高码率", 80: "1080P 高清", 74: "720P 60帧", 64: "720P", 32: "480P", 16: "360P"][id] ?? "画质 \(id)"
    }
}

enum DownloadState: String, Codable { case queued, preparing, downloading, merging, paused, completed, failed
    var title: String {
        switch self {
        case .queued: return "等待下载"
        case .preparing: return "正在获取下载链接"
        case .downloading: return "下载中"
        case .merging: return "正在合并"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "下载失败"
        }
    }
    var active: Bool { [.preparing, .downloading, .merging].contains(self) }
}

struct DownloadOptions: Codable {
    var quality = 80
    var codec = 7
    var audio = "标准"
    var audioOnly = false
    var keepAudio = false
    var danmaku = false
    var connections: Int? = nil
}

struct DownloadItem: Codable, Identifiable {
    var id = UUID()
    var title: String
    var part: VideoPart
    var cover: URL?
    var folder: URL
    var options: DownloadOptions
    var state: DownloadState = .queued
    var progress = 0.0
    var detail = "等待下载"
    var output: URL?
    var created = Date()
    var fileStem: String { Self.safeName(title) + "_\(part.cid)_" + id.uuidString.prefix(6) }
    static func safeName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0\n\r").union(.controlCharacters)
        let clean = title.components(separatedBy: forbidden).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return String((clean.isEmpty || clean == "." || clean == ".." ? "BiliDownloader" : clean).prefix(100))
    }
}

enum AppPaths {
    static var support: URL {
        if let override = ProcessInfo.processInfo.environment["BILIMAC_DATA_DIR"] { return URL(fileURLWithPath: override) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BiliDownloader")
    }
    static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("BiliDownloader")
    }
    static func prepare() throws { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true) }
}
