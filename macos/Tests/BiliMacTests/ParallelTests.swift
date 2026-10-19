import XCTest
import CryptoKit
@testable import BiliMac

final class ParallelTests: XCTestCase {
    private func base() throws -> URL {
        guard let text = ProcessInfo.processInfo.environment["BILIMAC_FIXTURE_BASE"], let url = URL(string: text) else { throw XCTSkip("Run scripts/test.sh") }
        return url
    }
    private func temporary() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private var expected: Data { Data((0..<(8 * 1024 * 1024)).map { UInt8($0 % 251) }) }
    private func stats(_ path: String) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(from: base().appendingPathComponent(path))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }
    func testConcurrentRangesMatchHashAndRespectLimit() async throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await stats("reset")
        let file = folder.appendingPathComponent("result.bin")
        _ = try await ParallelTransfer.download(url: base().appendingPathComponent("blob"), cookie: "", destination: file,
            resumeFile: folder.appendingPathComponent("resume"), connections: 3, progress: { _, _ in })
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: file)), SHA256.hash(data: expected))
        let status = try await stats("stats")
        XCTAssertGreaterThan(status["peak"] as! Int, 1)
        XCTAssertLessThanOrEqual(status["peak"] as! Int, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("parts").path))
    }
    func testParallelPauseReusesCompletedPieces() async throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await stats("reset")
        let file = folder.appendingPathComponent("result.bin"), resume = folder.appendingPathComponent("resume")
        let task = Task {
            try await ParallelTransfer.download(url: base().appendingPathComponent("blob"), cookie: "", destination: file,
                resumeFile: resume, connections: 2, progress: { _, _ in })
        }
        try await Task.sleep(for: .milliseconds(350)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let pieces = try FileManager.default.contentsOfDirectory(at: file.appendingPathExtension("parts"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "part" }
        XCTAssertFalse(pieces.isEmpty)
        let completedStarts = Set(pieces.compactMap { Int64($0.deletingPathExtension().lastPathComponent) }.map { $0 * 1024 * 1024 })
        let before = (try await stats("stats")["ranges"] as! [[Any]]).count
        _ = try await ParallelTransfer.download(url: base().appendingPathComponent("blob"), cookie: "", destination: file,
            resumeFile: resume, connections: 2, progress: { _, _ in })
        let later = (try await stats("stats")["ranges"] as! [[Any]]).dropFirst(before)
        for request in later where (request[2] as! Int64) > 0 {
            XCTAssertFalse(completedStarts.contains(request[1] as! Int64), "Completed chunks should not download twice")
        }
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: file)), SHA256.hash(data: expected))
    }
    func testIgnoredAndInvalidRangesRestartWithoutCorruption() async throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        for endpoint in ["no-range", "bad-range", "changed"] {
            let file = folder.appendingPathComponent(endpoint)
            _ = try await ParallelTransfer.download(url: base().appendingPathComponent(endpoint), cookie: "", destination: file,
                resumeFile: folder.appendingPathComponent(endpoint + ".resume"), connections: 3, progress: { _, _ in })
            let expectedBytes = endpoint == "changed" ? Data(expected.map { $0 ^ 0x55 }) : expected
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: file)), SHA256.hash(data: expectedBytes), endpoint)
        }
    }
    func testRangeParsingAndWeakValidators() throws {
        XCTAssertNil(RangeIdentity.contentRange("bytes 1-0/5"))
        XCTAssertNil(RangeIdentity.contentRange("bytes 0-9/9"))
        XCTAssertNil(RangeIdentity.contentRange("bytes */50"))
        let url = URL(string: "https://cdn.example.com/video")!
        let weak = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 0-0/8000000", "ETag": "W/\"v1\""])!
        XCTAssertNil(RangeIdentity.probe(weak))
        let strong = HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: ["Content-Range": "bytes 0-0/8000000", "ETag": "\"v1\""])!
        let identity = try XCTUnwrap(RangeIdentity.probe(strong))
        XCTAssertEqual(identity.ranges.first?.start, 0)
        XCTAssertEqual(identity.ranges.last?.end, 7999999)
        XCTAssertEqual(identity.ranges.reduce(0) { $0 + $1.size }, 8000000)
        XCTAssertEqual(identity.ranges.count, 8)
    }
}
