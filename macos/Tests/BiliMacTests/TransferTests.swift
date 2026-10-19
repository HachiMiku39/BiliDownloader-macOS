import XCTest
import CryptoKit
@testable import BiliMac

final class TransferTests: XCTestCase {
    private func baseURL() throws -> URL {
        guard let base = ProcessInfo.processInfo.environment["BILIMAC_FIXTURE_BASE"], let url = URL(string: base) else {
            throw XCTSkip("Run scripts/test.sh to include the local HTTP/FFmpeg integration tests")
        }
        return url
    }
    func testPauseResumeProducesExactFile() async throws {
        let base = try baseURL()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("blob.bin"), resume = folder.appendingPathComponent("blob.resume")
        let first = MediaTransfer(destination: file, resumeFile: resume, progress: { _, _ in })
        let task = Task { try await first.run(url: base.appendingPathComponent("blob"), cookie: "") }
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected interruption") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: resume.path), "URLSession should preserve resumable data")
        let second = MediaTransfer(destination: file, resumeFile: resume, progress: { _, _ in })
        _ = try await second.run(url: base.appendingPathComponent("blob"), cookie: "")
        let bytes = try Data(contentsOf: file)
        let expected = Data((0..<(8 * 1024 * 1024)).map { UInt8($0 % 251) })
        XCTAssertEqual(SHA256.hash(data: bytes), SHA256.hash(data: expected))
        XCTAssertFalse(FileManager.default.fileExists(atPath: resume.path))
    }
    func testHTTPErrorNeverPublishesMedia() async throws {
        let base = try baseURL()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let transfer = MediaTransfer(destination: file, resumeFile: file.appendingPathExtension("resume"), progress: { _, _ in })
        do { _ = try await transfer.run(url: base.appendingPathComponent("forbidden"), cookie: ""); XCTFail("Expected HTTP 403") }
        catch { XCTAssertTrue(error.localizedDescription.contains("403")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testRealDASHDownloadAndFFmpegMerge() async throws {
        let base = try baseURL()
        guard let binary = FFmpeg.locate() else { throw XCTSkip("FFmpeg unavailable") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        StubProtocol.responder = { request in
            let raw: [String: Any]
            if request.url!.path.hasSuffix("/nav") {
                raw = ["code": -101, "data": ["wbi_img": ["img_url": "https://example.com/7cd084941338484aae1ad9425b84077c.png", "sub_url": "https://example.com/4932caff0ff746eab6f01bf08b70ac45.png"]]]
            } else {
                raw = ["code": 0, "data": ["dash": [
                    "video": [["id": 80, "codecid": 7, "baseUrl": base.appendingPathComponent("video.mp4").absoluteString]],
                    "audio": [["baseUrl": base.appendingPathComponent("audio.m4a").absoluteString, "bandwidth": 128000]]]]]
            }
            return (200, try JSONSerialization.data(withJSONObject: raw))
        }
        let api = BiliAPI(session: URLSession(configuration: config))
        let part = VideoPart(cid: 1, title: "fixture", index: 1, duration: 1, bvid: "BV17x411w7KC", aid: 170001)
        let item = DownloadItem(title: "测试 '文件' $(literal)", part: part, folder: folder, options: .init())
        let result = try await DownloadEngine.run(item, api: api, ffmpeg: binary) { _, _, _ in }
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.output.path))
        XCTAssertEqual(result.output.pathExtension, "mp4")
        XCTAssertGreaterThan(try Data(contentsOf: result.output).count, 1000)
        XCTAssertNil(result.warning)
        let process = Process(); process.executableURL = binary
        let pipe = Pipe(); process.standardError = pipe
        process.arguments = ["-hide_banner", "-i", result.output.path]
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
        process.waitUntilExit()
        XCTAssertTrue(output.contains("Video: h264"), output)
        XCTAssertTrue(output.contains("Audio: aac"), output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".BiliDownloader-\(item.id.uuidString)").path))
    }
}
