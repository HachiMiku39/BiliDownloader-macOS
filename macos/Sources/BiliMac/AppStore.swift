import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

enum AppSection: String, CaseIterable, Identifiable {
    case new = "新建下载", downloads = "下载队列", history = "已完成", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .new: return "plus.circle"; case .downloads: return "arrow.down.circle"; case .history: return "checkmark.circle"; case .settings: return "slider.horizontal.3" }
    }
}

@MainActor
final class AppStore: ObservableObject {
    let api = BiliAPI()
    @Published var section: AppSection = .new
    @Published var input = ""
    @Published var info: VideoInfo?
    @Published var playback: Playback?
    @Published var selectedParts = Set<Int>()
    @Published var options = DownloadOptions()
    @Published var isResolving = false
    @Published var error: String?
    @Published var notice: String?
    @Published var items: [DownloadItem] = []
    @Published var accountName: String?
    @Published var showLogin = false
    @Published var qrImage: NSImage?
    @Published var qrStatus = "正在生成二维码…"
    @Published var qrExpired = false
    @Published var folder: URL
    @Published var ffmpegPath: String
    @Published var parallelism: Int
    @Published var connections: Int
    @Published var appearance: String
    @Published var focusInput = UUID()
    @Published var queueFilter = ""
    private var runners: [UUID: Task<Void, Never>] = [:]
    private var loginTask: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var shuttingDown = false
    let previewMode: Bool

    init(preview: Bool = false) {
        previewMode = preview
        let defaults = UserDefaults.standard
        folder = URL(fileURLWithPath: defaults.string(forKey: "downloadFolder") ?? AppPaths.downloads.path)
        ffmpegPath = defaults.string(forKey: "ffmpegPath") ?? ""
        parallelism = max(1, min(4, defaults.integer(forKey: "parallelism") == 0 ? 2 : defaults.integer(forKey: "parallelism")))
        connections = max(1, min(8, defaults.integer(forKey: "connections") == 0 ? 4 : defaults.integer(forKey: "connections")))
        appearance = defaults.string(forKey: "appearance") ?? "system"
        if preview { return }
        do {
            try AppPaths.prepare()
            let file = AppPaths.support.appendingPathComponent("downloads.json")
            if FileManager.default.fileExists(atPath: file.path) {
                items = try JSONDecoder().decode([DownloadItem].self, from: Data(contentsOf: file))
                for index in items.indices where items[index].state.active || items[index].state == .queued {
                    items[index].state = .paused; items[index].detail = "点击继续，恢复上次下载"
                }
            }
        } catch { self.error = "读取下载记录失败：\(error.localizedDescription)" }
        Task {
            do {
                let cookie = try CookieVault.load()
                await api.setCookie(cookie)
                if !cookie.isEmpty {
                    accountName = try await api.account()
                    if accountName == nil { notice = "登录已过期，请重新扫码登录。" }
                }
            } catch { self.notice = "登录状态未能恢复：\(error.localizedDescription)" }
        }
    }
    var colorScheme: ColorScheme? { appearance == "light" ? .light : appearance == "dark" ? .dark : nil }
    var ffmpeg: URL? { FFmpeg.locate(custom: ffmpegPath) }
    var unfinished: [DownloadItem] { items.filter { $0.state != .completed } }
    var completed: [DownloadItem] { items.filter { $0.state == .completed } }
    var activeCount: Int { items.filter { $0.state.active }.count }
    var allSelected: Bool { !(info?.parts.isEmpty ?? true) && selectedParts.count == info?.parts.count }

    func savePreferences() {
        guard !previewMode else { return }
        let defaults = UserDefaults.standard
        defaults.set(folder.path, forKey: "downloadFolder")
        defaults.set(ffmpegPath, forKey: "ffmpegPath")
        defaults.set(parallelism, forKey: "parallelism")
        defaults.set(connections, forKey: "connections")
        defaults.set(appearance, forKey: "appearance")
        schedule()
    }
    func saveItems() {
        guard !previewMode else { return }
        do {
            try AppPaths.prepare()
            let data = try JSONEncoder().encode(items)
            try data.write(to: AppPaths.support.appendingPathComponent("downloads.json"), options: .atomic)
        } catch { notice = "下载记录保存失败：\(error.localizedDescription)" }
    }
    private func delayedSave() {
        guard saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            saveItems(); saveTask = nil
        }
    }
    func resolve() {
        guard !isResolving else { return }
        let text = input
        isResolving = true; error = nil; notice = nil; info = nil; playback = nil
        resolveTask = Task {
            defer { isResolving = false }
            do {
                let result = try await api.resolve(text)
                try Task.checkCancellation()
                info = result
                selectedParts = Set(result.parts.map(\.cid))
                // Keep metadata visible even when playback is restricted.
                let media = try await api.playback(result.parts[0])
                try Task.checkCancellation()
                playback = media
                if let quality = media.qualities.first(where: { $0 <= options.quality }) ?? media.qualities.first { options.quality = quality }
                if !media.audios.contains(where: { $0.label == options.audio }) { options.audio = "标准" }
                if media.preview { notice = "当前账号只能试看。请登录拥有权限的账号后重新解析。" }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func paste() {
        if let text = NSPasteboard.general.string(forType: .string) { input = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    func newDownload(paste: Bool = false) {
        section = .new
        if paste { self.paste() }
        focusInput = UUID()
    }
    func toggleAll() { selectedParts = allSelected ? [] : Set(info?.parts.map(\.cid) ?? []) }
    func enqueue() {
        guard let info, !selectedParts.isEmpty else { return }
        guard ffmpeg != nil else { error = "内置媒体工具缺失，请重新安装完整 App，或在设置中选择 FFmpeg。"; return }
        guard playback?.preview != true else { error = "当前仅有试看片段，请登录拥有权限的账号后重新解析。"; return }
        for part in info.parts where selectedParts.contains(part.cid) {
            let title = info.parts.count == 1 ? info.title : "\(info.title) · P\(part.index) \(part.title)"
            var itemOptions = options; itemOptions.connections = connections
            items.insert(.init(title: title, part: part, cover: info.cover, folder: folder, options: itemOptions), at: 0)
        }
        saveItems(); section = .downloads; schedule()
    }
    func schedule() {
        guard !previewMode, !shuttingDown, let binary = ffmpeg else { return }
        while runners.count < parallelism, let item = items.last(where: { $0.state == .queued && runners[$0.id] == nil }) {
            update(item.id, state: .preparing, progress: item.progress, detail: "正在获取下载链接")
            let id = item.id
            runners[id] = Task { [self] in
                do {
                    let result = try await DownloadEngine.run(item, api: api, ffmpeg: binary) { [weak self] state, progress, detail in
                        await self?.update(id, state: state, progress: progress, detail: detail)
                    }
                    if let index = items.firstIndex(where: { $0.id == id }) {
                        items[index].output = result.output
                        items[index].state = .completed; items[index].progress = 1
                        items[index].detail = result.warning ?? "已保存到 \(result.output.deletingLastPathComponent().lastPathComponent)"
                    }
                } catch {
                    if Task.isCancelled { update(id, state: .paused, progress: nil, detail: "已暂停，可继续下载") }
                    else { update(id, state: .failed, progress: nil, detail: error.localizedDescription) }
                }
                runners[id] = nil
                saveItems(); schedule()
            }
        }
        saveItems()
    }
    private func update(_ id: UUID, state: DownloadState, progress: Double?, detail: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        // Queued delegate callbacks must not move a paused/finished task backwards.
        if state == .downloading && ![.preparing, .downloading].contains(items[index].state) { return }
        items[index].state = state
        if let progress { items[index].progress = min(1, max(0, progress)) }
        items[index].detail = detail
        delayedSave()
    }
    func pause(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state != .merging else { return }
        if let runner = runners[id] { runner.cancel() }
        else { items[index].state = .paused; items[index].detail = "已暂停"; saveItems() }
    }
    func resume(_ id: UUID) {
        guard runners[id] == nil, let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard ffmpeg != nil else { error = "未找到 FFmpeg，请在设置中指定路径。"; return }
        items[index].state = .queued; items[index].detail = "等待下载"; saveItems(); schedule()
    }
    func pauseAll() { for item in items where item.state.active || item.state == .queued { pause(item.id) } }
    func resumeAll() {
        guard ffmpeg != nil else { error = "未找到 FFmpeg，请在设置中指定路径。"; return }
        for index in items.indices where [.paused, .failed].contains(items[index].state) && runners[items[index].id] == nil { items[index].state = .queued }
        saveItems(); schedule()
    }
    func remove(_ item: DownloadItem) {
        guard !item.state.active, runners[item.id] == nil else { return }
        let cache = item.folder.appendingPathComponent(".BiliDownloader-\(item.id.uuidString)")
        do {
            if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
            items.removeAll { $0.id == item.id }; saveItems()
        } catch { self.error = "清理临时文件失败：\(error.localizedDescription)" }
    }
    func reveal(_ item: DownloadItem) {
        if let output = item.output { NSWorkspace.shared.activateFileViewerSelecting([output]) }
        else { openFolder(item.folder) }
    }
    func openFolder(_ target: URL? = nil) {
        let directory = target ?? folder
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch { self.error = "无法打开下载文件夹：\(error.localizedDescription)" }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.directoryURL = folder
        panel.prompt = "选择下载文件夹"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.folder = url; self?.savePreferences() }
        }
    }
    func chooseFFmpeg() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.showsHiddenFiles = true; panel.allowsMultipleSelection = false; panel.prompt = "选择 FFmpeg"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard FileManager.default.isExecutableFile(atPath: url.path) else { self?.error = "所选文件没有执行权限。"; return }
                self?.ffmpegPath = url.path; self?.savePreferences()
            }
        }
    }
    func startLogin() { showLogin = true; refreshQR() }
    func refreshQR() {
        loginTask?.cancel(); qrImage = nil; qrStatus = "正在生成二维码…"; qrExpired = false
        loginTask = Task {
            do {
                let (url, key) = try await api.generateQR()
                try Task.checkCancellation()
                let filter = CIFilter.qrCodeGenerator(); filter.message = Data(url.utf8); filter.correctionLevel = "M"
                if let image = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)), let cg = CIContext().createCGImage(image, from: image.extent) {
                    qrImage = NSImage(cgImage: cg, size: .init(width: 224, height: 224))
                }
                qrStatus = "打开哔哩哔哩 App 扫码登录"
                for _ in 0..<90 {
                    try await Task.sleep(for: .seconds(2))
                    let (code, cookie) = try await api.pollQR(key)
                    try Task.checkCancellation()
                    switch code {
                    case 0:
                        guard let cookie else { throw BiliError.message("未收到登录凭据。") }
                        try CookieVault.save(cookie)
                        await api.setCookie(cookie)
                        accountName = try await api.account() ?? "已登录"
                        showLogin = false; notice = "登录成功。请重新解析视频以获取账号可用画质。"; return
                    case 86090: qrStatus = "扫码成功，请在手机上确认"
                    case 86038: qrExpired = true; qrStatus = "二维码已过期，点击刷新重试"; return
                    case 86101: break
                    default: throw BiliError.message("登录状态异常（\(code)），请刷新二维码。")
                    }
                }
                qrExpired = true; qrStatus = "二维码已过期，点击刷新重试"
            } catch {
                if !Task.isCancelled { qrExpired = true; qrStatus = error.localizedDescription }
            }
        }
    }
    func stopLogin() { loginTask?.cancel(); loginTask = nil }
    func logout() {
        do {
            try CookieVault.save(""); accountName = nil
            Task { await api.setCookie("") }
            notice = "已清除本机登录信息。"
        } catch { self.error = error.localizedDescription }
    }
    func shutDown() async {
        shuttingDown = true; resolveTask?.cancel(); loginTask?.cancel()
        for item in items where item.state == .queued { pause(item.id) }
        let active = runners
        for (id, runner) in active where items.first(where: { $0.id == id })?.state != .merging { runner.cancel() }
        for (_, runner) in active { await runner.value }
        saveTask?.cancel(); saveItems()
    }
}
