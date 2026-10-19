import XCTest
@testable import BiliMac

final class CoreTests: XCTestCase {
    func testVideoReferencesPreserveBVCaseAndParseSharingText() throws {
        XCTAssertEqual(try VideoReference.parse("分享 https://www.bilibili.com/video/BV1xx411c7mD/?p=2"), .bv("BV1xx411c7mD"))
        XCTAssertEqual(try VideoReference.parse("bv1xx411c7mD"), .bv("BV1xx411c7mD"))
        XCTAssertEqual(try VideoReference.parse("AV170001"), .av(170001))
        XCTAssertEqual(try VideoReference.parse("https://www.bilibili.com/bangumi/play/ep123"), .ep(123))
        XCTAssertEqual(try VideoReference.parse("md456"), .md(456))
        XCTAssertEqual(try VideoReference.parse("ss789"), .ss(789))
        for invalid in ["", "no video", "BV123", "av0", "BV1xx411c7mDxxx", "av9999999999999999999999999"] {
            XCTAssertThrowsError(try VideoReference.parse(invalid))
        }
    }
    func testWbiMatchesUpstreamPythonAlgorithm() throws {
        let result = try WbiSigner.sign(["foo": "114", "bar": "514", "baz": "1919810"],
            image: "7cd084941338484aae1ad9425b84077c", sub: "4932caff0ff746eab6f01bf08b70ac45", timestamp: 1702204169)
        XCTAssertEqual(result["w_rid"], "6149fdadf571698ca7e6a567265cd0ee")
        XCTAssertEqual(result["wts"], "1702204169")
        XCTAssertEqual(WbiSigner.query(["text": "中文 !()*'"]), "text=%E4%B8%AD%E6%96%87+%21%28%29%2A%27")
        XCTAssertThrowsError(try WbiSigner.sign([:], image: "short", sub: "", timestamp: 0))
    }
    func testPlaybackQualityCodecAudioFallbackAndPGCNesting() throws {
        let raw: [String: Any] = ["video_info": [
            "dash": ["video": [
                ["id": 80, "codecid": 7, "baseUrl": "https://example.com/avc"],
                ["id": 80, "codecid": 12, "base_url": "https://example.com/hevc"],
                ["id": 32, "codecid": 7, "baseUrl": "https://example.com/480"]
            ], "audio": [["baseUrl": "https://example.com/aac", "bandwidth": 128000]],
            "flac": ["audio": ["baseUrl": "https://example.com/flac", "bandwidth": 990000]]],
            "accept_quality": [80, 32], "accept_description": ["1080P", "480P"]
        ]]
        let playback = try Playback.parse(raw)
        XCTAssertEqual(playback.qualities, [80, 32])
        XCTAssertEqual(playback.selectVideo(quality: 120, codec: 12)?.url.lastPathComponent, "hevc")
        XCTAssertEqual(playback.selectVideo(quality: 64, codec: 13)?.quality, 32)
        XCTAssertEqual(playback.selectVideo(quality: 16, codec: 7)?.quality, 32)
        XCTAssertEqual(playback.selectAudio(preferred: "FLAC")?.label, "FLAC")
        XCTAssertEqual(playback.selectAudio(preferred: "Dolby")?.label, "标准")
        XCTAssertEqual(playback.qualityName(80), "1080P")
        XCTAssertThrowsError(try Playback.parse([:]))
        XCTAssertTrue(try Playback.parse(["is_preview": 1, "durl": [["url": "https://example.com/preview"]]]).preview)
        XCTAssertNil(MediaStream.parse(["baseUrl": "file:///etc/passwd"]))
    }
    func testFilenameAndQueueRoundtrip() throws {
        let part = VideoPart(cid: 3, title: "分集", index: 1, duration: 90, bvid: "BV1xx411c7mD", aid: 170001)
        let item = DownloadItem(title: "../片名/测试:\n", part: part, folder: URL(fileURLWithPath: "/tmp/test"), options: .init())
        XCTAssertFalse(item.fileStem.contains("/")); XCTAssertFalse(item.fileStem.contains("\n"))
        XCTAssertEqual(DownloadItem.safeName(".."), "BiliDownloader")
        XCTAssertEqual(part.durationText, "1:30")
        let decoded = try JSONDecoder().decode(DownloadItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.id, item.id); XCTAssertEqual(decoded.fileStem, item.fileStem)
    }
    func testDanmakuEscapesASSControlCodesAndRejectsInvalidXML() throws {
        let xml = Data("<i><d p=\"1.5,1,25,16711680,0,0,0,0\">hello {\\pos(0,0)} &amp; 世界</d><d p=\"2,7,25,1\">advanced</d></i>".utf8)
        let result = try DanmakuConverter.convert(xml)
        XCTAssertTrue(result.contains("0:00:01.50,0:00:09.50"))
        XCTAssertTrue(result.contains("\\c&H0000FF&"))
        XCTAssertTrue(result.contains("｛＼pos(0,0)｝"))
        XCTAssertFalse(result.contains("advanced"))
        XCTAssertTrue(try DanmakuConverter.convert(Data("<i><d p=\"0,1,25,1\"><![CDATA[hello <world>]]></d></i>".utf8)).contains("hello <world>"))
        XCTAssertThrowsError(try DanmakuConverter.convert(Data("<not-xml".utf8)))
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static var responder: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.responder!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class APITests: XCTestCase {
    private func api() -> BiliAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return BiliAPI(session: URLSession(configuration: config))
    }
    func testMetadataAndSignedPlayurl() async throws {
        StubProtocol.responder = { request in
            let url = request.url!
            let json: [String: Any]
            switch url.path {
            case "/x/web-interface/view":
                json = ["code": 0, "data": ["aid": 170001, "bvid": "BV1xx411c7mD", "title": "测试视频", "owner": ["name": "UP"],
                    "pages": [["cid": 123, "part": "P1", "duration": 88]]]]
            case "/x/web-interface/nav":
                json = ["code": -101, "data": ["wbi_img": ["img_url": "https://i.example.com/7cd084941338484aae1ad9425b84077c.png", "sub_url": "https://i.example.com/4932caff0ff746eab6f01bf08b70ac45.png"]]]
            default:
                let params = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(params.first(where: { $0.name == "w_rid" })?.value?.count, 32)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "SESSDATA=test")
                json = ["code": 0, "data": ["durl": [["url": "https://cdn.example.com/test.mp4"]]]]
            }
            return (200, try JSONSerialization.data(withJSONObject: json))
        }
        let api = api(); await api.setCookie("SESSDATA=test")
        let info = try await api.resolve("av170001")
        XCTAssertEqual(info.title, "测试视频"); XCTAssertEqual(info.parts.first?.cid, 123)
        let media = try await api.playback(info.parts[0])
        XCTAssertEqual(media.segments.count, 1)
    }
    func testAPIErrorsAreSurfaced() async throws {
        StubProtocol.responder = { _ in (200, Data("{\"code\":-404,\"message\":\"视频不存在\"}".utf8)) }
        do { _ = try await api().resolve("av170001"); XCTFail("Expected API error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("视频不存在")) }
    }
}
