import Foundation

enum RangeFailure: LocalizedError {
    case inconsistent
    var errorDescription: String? { "服务器的分段响应或文件版本不一致，已停止拼接。" }
}

struct RangeIdentity: Codable, Equatable, Sendable {
    var resource: String
    var total: Int64
    var validatorHeader: String
    var validator: String
    var chunkSize: Int64 = 1024 * 1024

    static func contentRange(_ value: String?) -> (Int64, Int64, Int64)? {
        guard let value, value.hasPrefix("bytes ") else { return nil }
        let pieces = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, let total = Int64(pieces[1]), total > 0 else { return nil }
        let bounds = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }
    static func probe(_ response: HTTPURLResponse) -> RangeIdentity? {
        guard response.statusCode == 206,
              let (start, end, total) = contentRange(response.value(forHTTPHeaderField: "Content-Range")),
              start == 0, end == 0,
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true,
              let url = response.url else { return nil }
        let resource = (url.host ?? "") + url.path
        if let tag = response.value(forHTTPHeaderField: "ETag")?.trimmingCharacters(in: .whitespaces),
           tag.hasPrefix("\""), tag.hasSuffix("\""), tag.count >= 2,
           !tag.dropFirst().dropLast().contains("\"") {
            return .init(resource: resource, total: total, validatorHeader: "ETag", validator: tag)
        }
        // Weak ETags cannot authorize combining representations. A date validator
        // is used only when it satisfies the HTTP 60-second strength heuristic.
        if response.value(forHTTPHeaderField: "ETag") != nil { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let modified = response.value(forHTTPHeaderField: "Last-Modified"),
           let date = response.value(forHTTPHeaderField: "Date"),
           let m = formatter.date(from: modified), let d = formatter.date(from: date), d.timeIntervalSince(m) >= 60 {
            return .init(resource: resource, total: total, validatorHeader: "Last-Modified", validator: modified)
        }
        return nil
    }
    var ranges: [ByteRangeRequest] {
        var result: [ByteRangeRequest] = []
        var start: Int64 = 0
        let span = max(chunkSize, (total - 1) / 4096 + 1)
        while start < total {
            let end = start + min(span, total - start) - 1
            result.append(.init(start: start, end: end, identity: self)); start = end + 1
        }
        return result
    }
}

struct ByteRangeRequest: Sendable {
    var start: Int64
    var end: Int64
    var identity: RangeIdentity
    var size: Int64 { end - start + 1 }
    func validate(response: HTTPURLResponse, actualSize: Int64) throws {
        guard response.statusCode == 206,
              let (a, b, total) = RangeIdentity.contentRange(response.value(forHTTPHeaderField: "Content-Range")),
              a == start, b == end, total == identity.total, actualSize == size,
              response.url.map({ ($0.host ?? "") + $0.path }) == identity.resource,
              response.value(forHTTPHeaderField: identity.validatorHeader) == identity.validator,
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0 == "identity" }) ?? true else {
            throw RangeFailure.inconsistent
        }
    }
}

/// Probe headers only. A server ignoring Range must not force the whole media
/// body into memory or download an unnecessary second copy during discovery.
private final class RangeProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RangeIdentity?, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    func run(url: URL, cookie: String) async throws -> RangeIdentity? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false
                config.timeoutIntervalForRequest = 20
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                var request = URLRequest(url: url)
                request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                request.setValue(BiliAPI.userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
                if let host = url.host, host == "bilibili.com" || host.hasSuffix(".bilibili.com") { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
                task = session.dataTask(with: request); task?.resume(); lock.unlock()
            }
        } onCancel: { self.cancel() }
    }
    private func takeContinuation() -> CheckedContinuation<RangeIdentity?, Error>? {
        lock.lock(); defer { lock.unlock() }
        let value = continuation; continuation = nil; return value
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            if [200, 206].contains(http.statusCode) { takeContinuation()?.resume(returning: RangeIdentity.probe(http)) }
            else { takeContinuation()?.resume(throwing: BiliError.message("下载服务器返回 HTTP \(http.statusCode)")) }
        } else { takeContinuation()?.resume(returning: nil) }
        completionHandler(.cancel)
        session.invalidateAndCancel(); self.session = nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { takeContinuation()?.resume(throwing: error) }
        else { takeContinuation()?.resume(returning: nil) }
        session.finishTasksAndInvalidate(); self.session = nil
    }
}

private actor RangeProgress {
    private var sizes: [Int: Int64]
    private let total: Int64
    private let callback: @Sendable (Int64, Int64) -> Void
    private var active = true
    init(sizes: [Int: Int64], total: Int64, callback: @escaping @Sendable (Int64, Int64) -> Void) {
        self.sizes = sizes; self.total = total; self.callback = callback
    }
    func report(_ index: Int, _ value: Int64) {
        guard active else { return }
        sizes[index] = value
        callback(sizes.values.reduce(0, +), total)
    }
    func stop() { active = false }
}

enum ParallelTransfer {
    static func download(url: URL, cookie: String, destination: URL, resumeFile: URL,
                         connections: Int, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let connectionCount = min(8, max(1, connections))
        let folder = destination.appendingPathExtension("parts")
        if connectionCount > 1, let identity = try await RangeProbe().run(url: url, cookie: cookie), identity.total >= 2 * 1024 * 1024 {
            do {
                return try await parallel(url: url, cookie: cookie, destination: destination,
                    folder: folder, identity: identity, connections: connectionCount, progress: progress)
            } catch is RangeFailure {
                // A changed/ignored range invalidates every previous piece. Only
                // restart after all child tasks have stopped; never append a 200
                // response to an old prefix or publish a mix of file versions.
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: folder)
                try? FileManager.default.removeItem(at: resumeFile)
            }
        }
        try Task.checkCancellation()
        return try await MediaTransfer(destination: destination, resumeFile: resumeFile, progress: progress).run(url: url, cookie: cookie)
    }
    private static func parallel(url: URL, cookie: String, destination: URL, folder: URL,
                                 identity: RangeIdentity, connections: Int,
                                 progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        let fm = FileManager.default
        let manifest = folder.appendingPathComponent("manifest.json")
        let old = try? JSONDecoder().decode(RangeIdentity.self, from: Data(contentsOf: manifest))
        if fm.fileExists(atPath: folder.path), old != identity {
            try fm.removeItem(at: folder)
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try JSONEncoder().encode(identity).write(to: manifest, options: .atomic)
        let ranges = identity.ranges
        func partFile(_ index: Int) -> URL { folder.appendingPathComponent("\(index).part") }
        var finished: [Int: Int64] = [:]
        for (index, range) in ranges.enumerated() {
            if let attributes = try? fm.attributesOfItem(atPath: partFile(index).path),
               (attributes[.size] as? NSNumber)?.int64Value == range.size { finished[index] = range.size }
        }
        let reporter = RangeProgress(sizes: finished, total: identity.total, callback: progress)
        let missing = ranges.indices.filter { finished[$0] == nil }
        do {
            try await withThrowingTaskGroup(of: Int.self) { group in
                var pending = missing.makeIterator()
                func launch(_ index: Int) {
                    group.addTask {
                        let range = ranges[index]
                        for attempt in 0..<3 {
                            try Task.checkCancellation()
                            do {
                                _ = try await MediaTransfer(destination: partFile(index),
                                    resumeFile: folder.appendingPathComponent("unused-\(index).resume"), range: range,
                                    progress: { done, _ in Task { await reporter.report(index, done) } })
                                    .run(url: url, cookie: cookie, useResume: false)
                                await reporter.report(index, range.size)
                                return index
                            } catch is RangeFailure { throw RangeFailure.inconsistent }
                            catch {
                                if Task.isCancelled { throw CancellationError() }
                                if attempt == 2 { throw error }
                                await reporter.report(index, 0)
                                try await Task.sleep(for: .milliseconds(350 * (attempt + 1)))
                            }
                        }
                        throw BiliError.message("分段重试失败。")
                    }
                }
                for _ in 0..<min(connections, missing.count) { if let index = pending.next() { launch(index) } }
                while try await group.next() != nil { if let index = pending.next() { launch(index) } }
            }
            await reporter.stop()
            let staging = folder.appendingPathComponent("assembled.media")
            fm.createFile(atPath: staging.path, contents: nil)
            let output = try FileHandle(forWritingTo: staging)
            do {
                try output.truncate(atOffset: 0)
                for index in ranges.indices {
                    try Task.checkCancellation()
                    let file = partFile(index)
                    let size = (try fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
                    guard size == ranges[index].size else { throw RangeFailure.inconsistent }
                    let input = try FileHandle(forReadingFrom: file)
                    do {
                        while let bytes = try input.read(upToCount: 256 * 1024), !bytes.isEmpty {
                            try Task.checkCancellation(); try output.write(contentsOf: bytes)
                        }
                        try input.close()
                    } catch { try? input.close(); throw error }
                }
                try output.synchronize(); try output.close()
            } catch { try? output.close(); throw error }
            guard (try fm.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value == identity.total else { throw RangeFailure.inconsistent }
            try fm.moveItem(at: staging, to: destination)
            try? fm.removeItem(at: folder)
            progress(identity.total, identity.total)
            return destination
        } catch { await reporter.stop(); throw error }
    }
}
