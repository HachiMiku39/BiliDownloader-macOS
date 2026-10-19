import Foundation

/// A download delegate keeps the large media body on disk. URLSession manages
/// HTTP range/validator checks and supplies resumable data when interrupted.
final class MediaTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let resumeFile: URL
    private let range: ByteRangeRequest?
    private let progress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var completedFile: URL?
    private var fileError: Error?
    private var lastProgress = Date.distantPast
    init(destination: URL, resumeFile: URL, range: ByteRangeRequest? = nil, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination; self.resumeFile = resumeFile; self.range = range; self.progress = progress
    }
    func run(url: URL, cookie: String, useResume: Bool = true) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 30
                config.timeoutIntervalForResource = 24 * 60 * 60
                config.httpShouldSetCookies = false
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                if range == nil, useResume, let data = try? Data(contentsOf: resumeFile), !data.isEmpty {
                    task = session.downloadTask(withResumeData: data)
                } else {
                    var request = URLRequest(url: url)
                    request.setValue(BiliAPI.userAgent, forHTTPHeaderField: "User-Agent")
                    request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    if let range {
                        request.setValue("bytes=\(range.start)-\(range.end)", forHTTPHeaderField: "Range")
                        request.setValue(range.identity.validator, forHTTPHeaderField: "If-Range")
                    }
                    // CDN URLs already carry authorization. Never forward account cookies
                    // to arbitrary media hosts.
                    if let host = url.host, host == "bilibili.com" || host.hasSuffix(".bilibili.com") {
                        request.setValue(cookie, forHTTPHeaderField: "Cookie")
                    }
                    task = session.downloadTask(with: request)
                }
                task?.resume()
                lock.unlock()
            }
        } onCancel: { self.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel(byProducingResumeData: { _ in })
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if Date().timeIntervalSince(lastProgress) >= 0.15 || totalBytesWritten == totalBytesExpectedToWrite {
            lastProgress = Date()
            progress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, [200, 206].contains(response.statusCode) else {
            fileError = BiliError.message("下载服务器返回 HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)，请重试以刷新链接。")
            return
        }
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            if let range { try range.validate(response: downloadTask.response as! HTTPURLResponse, actualSize: size) }
            guard size > 0 else { throw BiliError.message("下载服务器返回了空文件。") }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.removeItem(at: resumeFile)
            completedFile = destination
        } catch { fileError = error }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if range == nil, let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resumeFile.path)
        }
        lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock()
        if let fileError { continuation?.resume(throwing: fileError) }
        else if let error { continuation?.resume(throwing: error) }
        else if let completedFile { continuation?.resume(returning: completedFile) }
        else { continuation?.resume(throwing: BiliError.message("下载未生成文件。")) }
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}

enum FFmpeg {
    static var bundledURL: URL? { Bundle.main.resourceURL?.appendingPathComponent("ffmpeg") }
    static func locate(custom: String = "") -> URL? {
        let bundled = bundledURL?.path ?? ""
        let testOverride = ProcessInfo.processInfo.environment["BILIMAC_FFMPEG"] ?? ""
        let candidates = [testOverride, custom, bundled, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/ffmpeg" }
        return candidates.first(where: { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    static func run(binary: URL, arguments: [String], log: URL) async throws {
        // No shell: paths, video titles and remote input cannot become commands.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    FileManager.default.createFile(atPath: log.path, contents: nil)
                    let handle = try FileHandle(forWritingTo: log)
                    defer { try? handle.close() }
                    let process = Process()
                    process.executableURL = binary
                    process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-n"] + arguments
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = handle
                    try process.run(); process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                        throw BiliError.message("FFmpeg 合并失败（\(process.terminationStatus)）：\(text.suffix(900))")
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

struct DownloadResult { var output: URL; var warning: String? }

enum DownloadEngine {
    typealias Update = @Sendable (DownloadState, Double, String) async -> Void
    static func run(_ item: DownloadItem, api: BiliAPI, ffmpeg: URL, update: @escaping Update) async throws -> DownloadResult {
        let fm = FileManager.default
        try fm.createDirectory(at: item.folder, withIntermediateDirectories: true)
        let cache = item.folder.appendingPathComponent(".BiliDownloader-\(item.id.uuidString)", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cache.path)
        try Task.checkCancellation()
        let playback = try await api.playback(item.part, quality: item.options.quality)
        // A paid preview must never be silently presented as a complete download.
        guard !playback.preview else { throw BiliError.message("B 站只返回了试看片段。请登录拥有该内容权限的账号后重试。") }
        let cookie = await api.cookieHeader()
        var inputs: [URL] = []
        let audio = playback.selectAudio(preferred: item.options.audio)
        let video = playback.selectVideo(quality: item.options.quality, codec: item.options.codec)
        var streams: [(String, MediaStream)] = []
        if !playback.segments.isEmpty && video == nil {
            streams = playback.segments.enumerated().map { ("segment-\($0.offset)", $0.element) }
        } else {
            if !item.options.audioOnly, let video { streams.append(("video", video)) }
            if let audio { streams.append(("audio-\(audio.label)", audio)) }
            else if item.options.audioOnly { throw BiliError.message("该视频没有可下载的音频流。") }
        }
        guard !streams.isEmpty else { throw BiliError.message("未找到匹配的视频流。") }
        // Completed pieces are reusable only when stream identity is unchanged.
        // Signed URLs expire, so identity deliberately excludes URL query tokens.
        let identity = streams.map { "\($0.0):\($0.1.quality):\($0.1.codec):\($0.1.url.path)" }.joined(separator: "\n")
        let identityFile = cache.appendingPathComponent("identity.txt")
        if (try? String(contentsOf: identityFile, encoding: .utf8)) != identity {
            for file in try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil) { try fm.removeItem(at: file) }
            try identity.write(to: identityFile, atomically: true, encoding: .utf8)
        }
        let streamCount = streams.count
        for (index, entry) in streams.enumerated() {
            try Task.checkCancellation()
            let file = cache.appendingPathComponent(entry.0 + ".media")
            if !fm.fileExists(atPath: file.path) {
                let resume = cache.appendingPathComponent(entry.0 + ".resume")
                let notify: @Sendable (Int64, Int64) -> Void = { done, total in
                    let fraction = total > 0 ? Double(done) / Double(total) : 0
                    let ratio = (Double(index) + fraction) / Double(streamCount) * 0.94
                    let detail = "\(entry.0 == "video" ? "视频" : entry.0.hasPrefix("audio") ? "音频" : "分段") · \(ByteCountFormatter.string(fromByteCount: done, countStyle: .file))" + (total > 0 ? " / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))" : "")
                    Task { await update(.downloading, ratio, detail) }
                }
                do {
                    _ = try await ParallelTransfer.download(url: entry.1.url, cookie: cookie, destination: file,
                        resumeFile: resume, connections: item.options.connections ?? 4, progress: notify)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    // Expired resume URLs and stale resume data are retried once with
                    // the freshly resolved URL. Failed files are never marked complete.
                    try? fm.removeItem(at: resume)
                    _ = try await MediaTransfer(destination: file, resumeFile: resume, progress: notify).run(url: entry.1.url, cookie: cookie, useResume: false)
                }
            }
            inputs.append(file)
        }
        try Task.checkCancellation()
        await update(.merging, 0.96, "正在无损合并，请稍候")
        let isFlac = audio?.label == "FLAC"
        let ext = item.options.audioOnly ? (isFlac ? "flac" : "m4a") : "mp4"
        let output = item.folder.appendingPathComponent(item.fileStem + "." + ext)
        // Merge into a private staging file, then publish without overwriting.
        let staging = cache.appendingPathComponent("merged." + ext)
        try? fm.removeItem(at: staging)
        var arguments: [String] = []
        if video == nil && !playback.segments.isEmpty {
            let list = cache.appendingPathComponent("concat.txt")
            let content = inputs.map { "file '\($0.lastPathComponent)'" }.joined(separator: "\n")
            try content.write(to: list, atomically: true, encoding: .utf8)
            arguments = ["-f", "concat", "-safe", "1", "-i", list.path]
            if item.options.audioOnly { arguments += ["-vn"] }
        } else {
            for input in inputs { arguments += ["-i", input.path] }
            if item.options.audioOnly { arguments += ["-map", "0:a:0", "-vn"] }
            else {
                arguments += ["-map", "0:v:0"]
                if inputs.count > 1 { arguments += ["-map", "1:a:0"] }
            }
        }
        arguments += ["-c", "copy"]
        if ext == "mp4" { arguments += ["-movflags", "+faststart", "-strict", "-2"] }
        arguments.append(staging.path)
        try await FFmpeg.run(binary: ffmpeg, arguments: arguments, log: cache.appendingPathComponent("ffmpeg.log"))
        try fm.moveItem(at: staging, to: output)
        var warnings: [String] = []
        if item.options.keepAudio && !item.options.audioOnly, let audioIndex = streams.firstIndex(where: { $0.0.hasPrefix("audio-") }) {
            do { try fm.copyItem(at: inputs[audioIndex], to: item.folder.appendingPathComponent(item.fileStem + (isFlac ? ".flac" : ".m4a"))) }
            catch { warnings.append("独立音频保存失败：\(error.localizedDescription)") }
        }
        if item.options.danmaku {
            do {
                let xml = try await api.danmaku(item.part.cid)
                try xml.write(to: item.folder.appendingPathComponent(item.fileStem + ".xml"), options: .atomic)
                let ass = try DanmakuConverter.convert(xml)
                try ass.write(to: item.folder.appendingPathComponent(item.fileStem + ".ass"), atomically: true, encoding: .utf8)
            } catch { warnings.append("视频已保存，弹幕导出失败：\(error.localizedDescription)") }
        }
        if !item.options.audioOnly, let video, video.quality != item.options.quality {
            warnings.append("所选画质\(playback.qualityName(item.options.quality))未提供，实际下载：\(playback.qualityName(video.quality))")
        }
        try? fm.removeItem(at: cache)
        return .init(output: output, warning: warnings.isEmpty ? nil : warnings.joined(separator: "；"))
    }
}

final class DanmakuConverter: NSObject, XMLParserDelegate {
    private var attributes: [String] = []
    private var current = ""
    private var comments: [(Double, Int, Int, String)] = []
    private var inside = false
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "d" { attributes = (attributeDict["p"] ?? "").components(separatedBy: ","); current = ""; inside = true }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inside { current += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if inside, let text = String(data: CDATABlock, encoding: .utf8) { current += text }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "d" {
            inside = false
            if attributes.count >= 4, let time = Double(attributes[0]), time.isFinite, time >= 0,
               let mode = Int(attributes[1]), let color = Int(attributes[3]), [1,2,3,4,5].contains(mode) {
                comments.append((time, mode, color, current))
            }
        }
    }
    static func timestamp(_ value: Double) -> String {
        let cs = Int((max(0, value) * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", cs / 360000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
    }
    static func convert(_ data: Data) throws -> String {
        let delegate = DanmakuConverter()
        let parser = XMLParser(data: data); parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw BiliError.message("弹幕 XML 格式无效。") }
        var output = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        WrapStyle: 2
        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,PingFang SC,42,&H40FFFFFF,&H40FFFFFF,&H60000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,7,0,0,0,1
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        var lanes: [Int: Int] = [:]
        for (time, mode, color, text) in delegate.comments.sorted(by: { $0.0 < $1.0 }) {
            let lane = lanes[mode, default: 0] % 15; lanes[mode, default: 0] += 1
            let y = mode == 4 ? 1010 - lane * 52 : 36 + lane * 52
            let escaped = text.replacingOccurrences(of: "\\", with: "＼").replacingOccurrences(of: "{", with: "｛").replacingOccurrences(of: "}", with: "｝").replacingOccurrences(of: "\n", with: "\\N").replacingOccurrences(of: "\r", with: "")
            let bgr = ((color & 255) << 16) | (color & 0xff00) | ((color >> 16) & 255)
            let position = [4,5].contains(mode) ? "\\an8\\pos(960,\(y))" : "\\move(1920,\(y),-\(max(200, text.count * 44)),\(y))"
            output += "Dialogue: 0,\(timestamp(time)),\(timestamp(time + 8)),Default,,0,0,0,,{\(position)\\c&H\(String(format: "%06X", bgr))&}\(escaped)\n"
        }
        return output
    }
}
