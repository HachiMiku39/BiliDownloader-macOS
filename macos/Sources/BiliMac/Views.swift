import SwiftUI
import AppKit

extension Color {
    static let biliPink = Color(red: 0.94, green: 0.27, blue: 0.45)
    static let biliBlue = Color(red: 0.22, green: 0.57, blue: 0.91)
}

struct BrandMark: View {
    var size: CGFloat = 42
    var body: some View {
        Image(systemName: "arrow.down")
            .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [.init(red: 1, green: 0.48, blue: 0.62), .biliPink], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: size * 0.28))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28).strokeBorder(.white.opacity(0.32)))
            .shadow(color: .biliPink.opacity(0.15), radius: 8, y: 4)
    }
}

struct RootView: View {
    @EnvironmentObject var store: AppStore
    @State private var visibility = NavigationSplitViewVisibility.all
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            SidebarView().navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 270)
        } detail: {
            VStack(spacing: 0) {
                if let notice = store.notice {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundStyle(Color.biliBlue)
                        Text(notice).font(.callout)
                        Spacer()
                        Button { store.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("关闭提示")
                    }.padding(12).background(Color.biliBlue.opacity(0.07))
                }
                switch store.section {
                case .new: NewDownloadView()
                case .downloads: QueueView(completed: false)
                case .history: QueueView(completed: true)
                case .settings: PreferencesView()
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(store.section.rawValue)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { store.openFolder() } label: { Label("下载文件夹", systemImage: "folder") }
                        .help("打开下载文件夹（⌘⇧O）")
                    Button { store.startLogin() } label: {
                        Label(store.accountName ?? "登录", systemImage: store.accountName == nil ? "person.crop.circle" : "person.crop.circle.fill")
                    }.help(store.accountName ?? "扫码登录哔哩哔哩")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(.biliPink)
        .frame(minWidth: 940, minHeight: 650)
        .preferredColorScheme(store.colorScheme)
        .sheet(isPresented: $store.showLogin, onDismiss: { store.stopLogin() }) { LoginView() }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 11) {
                BrandMark(size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("BiliDownloader").font(.system(size: 15, weight: .semibold))
                    Text("你的 B 站收藏站").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 18).padding(.top, 24)
            List(selection: Binding<AppSection?>(get: { store.section }, set: { if let value = $0 { store.section = value } })) {
                Section("资料库") {
                    sidebarRow(.new)
                    sidebarRow(.downloads, count: store.unfinished.count)
                    sidebarRow(.history, count: store.completed.count)
                }
                Section("偏好") { sidebarRow(.settings) }
            }.listStyle(.sidebar)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle().fill(store.activeCount > 0 ? Color.biliPink : Color.green).frame(width: 6, height: 6)
                    Text(store.activeCount > 0 ? "\(store.activeCount) 个任务正在下载" : "准备就绪").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").font(.caption)
                    Text(store.folder.lastPathComponent).lineLimit(1).font(.caption)
                    Spacer()
                    Button { store.chooseFolder() } label: { Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)) }
                        .buttonStyle(.plain).help("更改下载文件夹")
                }.foregroundStyle(.secondary)
            }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12)).padding(14)
        }
    }
    private func sidebarRow(_ section: AppSection, count: Int = 0) -> some View {
        HStack {
            Label(section.rawValue, systemImage: section.symbol)
            Spacer()
            if count > 0 { Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
        }.padding(.vertical, 6).tag(section)
    }
}

struct ContentCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.padding(24)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.055)))
    }
}

struct NewDownloadView: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focused: Bool
    @State private var dropTarget = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                inputCard
                if let info = store.info {
                    VideoSelectionView(info: info)
                } else {
                    guidance
                    recentDownloads
                }
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                    Text("登录信息保存在 macOS 钥匙串 · 下载内容以账号权限为准")
                }.font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.bottom, 8)
            }.padding(34).frame(maxWidth: 1060).frame(maxWidth: .infinity)
        }
        .onChange(of: store.focusInput) { focused = true }
        .dropDestination(for: String.self) { values, _ in
            guard let text = values.first else { return false }
            store.input = text; return true
        } isTargeted: { dropTarget = $0 }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: 20).strokeBorder(Color.biliPink, style: StrokeStyle(lineWidth: 3, dash: [8])).padding(12).allowsHitTesting(false) } }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").foregroundStyle(Color.biliPink)
                Text("喜欢的内容，随时重温").foregroundStyle(.secondary)
            }.font(.system(size: 12, weight: .medium)).padding(.top, 12)
            Text("把喜欢，留在你的 Mac。").font(.system(size: 32, weight: .bold)).tracking(-0.8)
            Text("粘贴链接，选择画质。剩下的交给 BiliDownloader。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
        }
    }
    private var inputCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label("添加视频", systemImage: "link").font(.headline)
                    Spacer()
                    Text("⌘ N 新建").font(.caption).foregroundStyle(.tertiary)
                }
                HStack(spacing: 12) {
                    Image(systemName: "link").foregroundStyle(.secondary).padding(.leading, 15)
                    TextField("粘贴 B 站链接，或输入 BV / AV / EP / MD", text: $store.input)
                        .textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                        .onSubmit { store.resolve() }.accessibilityIdentifier("videoInput")
                    if !store.input.isEmpty {
                        Button { store.input = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }.buttonStyle(.plain).help("清空链接")
                    }
                    Button { store.paste() } label: { Image(systemName: "doc.on.clipboard") }.buttonStyle(.plain).padding(.trailing, 14).help("从剪贴板粘贴")
                }
                .frame(height: 52)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? Color.biliPink.opacity(0.6) : .primary.opacity(0.07)))
                HStack {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("视频 · 合集分 P · 番剧").foregroundStyle(.secondary)
                    }.font(.caption)
                    Spacer()
                    Button { store.resolve() } label: {
                        HStack(spacing: 8) {
                            if store.isResolving { ProgressView().controlSize(.small) }
                            Text(store.isResolving ? "正在解析…" : "解析视频")
                            if !store.isResolving { Image(systemName: "arrow.right") }
                        }.frame(minWidth: 100)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isResolving)
                    .accessibilityIdentifier("resolveButton")
                }
            }
        }
    }
    private var guidance: some View {
        HStack(alignment: .top, spacing: 22) {
            tip("01", "粘贴链接", "支持视频与番剧链接\n也可以直接输入视频编号", "link", .biliBlue)
            tip("02", "按你所需", "自由选择分集、画质\n支持仅音频与弹幕导出", "slider.horizontal.3", .biliPink)
            tip("03", "安心收藏", "暂停后随时继续\n在 Finder 中直接查看", "folder", .orange)
        }.padding(.horizontal, 2).padding(.vertical, 4)
    }
    private func tip(_ number: String, _ title: String, _ description: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(color).frame(width: 36, height: 36).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                Spacer()
                Text(number).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.quaternary)
            }
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(description).font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var recentDownloads: some View {
        if !store.completed.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("最近保存").font(.headline)
                    Spacer()
                    Button("查看全部") { store.section = .history }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.completed.prefix(2)) { item in
                    Button { store.reveal(item) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.rectangle.fill").foregroundStyle(Color.biliPink)
                            Text(item.title).lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up.forward").foregroundStyle(.tertiary)
                        }.font(.callout)
                    }.buttonStyle(.plain)
                }
            }.padding(.top, 8)
        }
    }
}

struct CoverView: View {
    var url: URL?
    var width: CGFloat = 170
    var height: CGFloat = 100
    var body: some View {
        AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: {
            ZStack {
                LinearGradient(colors: [Color.biliPink.opacity(0.16), Color.biliBlue.opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "play.rectangle").font(.system(size: 28)).foregroundStyle(Color.biliPink.opacity(0.55))
            }
        }.frame(width: width, height: height).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct VideoSelectionView: View {
    @EnvironmentObject var store: AppStore
    let info: VideoInfo
    var body: some View {
        VStack(spacing: 20) {
            ContentCard {
                HStack(alignment: .top, spacing: 20) {
                    CoverView(url: info.cover)
                    VStack(alignment: .leading, spacing: 9) {
                        Text(info.title).font(.system(size: 17, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                        Label(info.author, systemImage: "person.circle").font(.callout).foregroundStyle(.secondary)
                        Text("\(info.parts.count) 个分集 · \(info.id)").font(.caption).foregroundStyle(.tertiary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ContentCard {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("选择分集").font(.headline)
                        Text("已选 \(store.selectedParts.count) / \(info.parts.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(store.allSelected ? "取消全选" : "全选") { store.toggleAll() }.buttonStyle(.plain).foregroundStyle(Color.biliPink)
                    }
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(info.parts) { part in
                                Toggle(isOn: Binding(get: { store.selectedParts.contains(part.cid) }, set: { selected in
                                    if selected { store.selectedParts.insert(part.cid) } else { store.selectedParts.remove(part.cid) }
                                })) {
                                    HStack {
                                        Text("P\(part.index)").font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
                                        Text(part.title).lineLimit(1)
                                        Spacer()
                                        Text(part.durationText).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                    }
                                }.toggleStyle(.checkbox).padding(.vertical, 9)
                                if part.id != info.parts.last?.id { Divider() }
                            }
                        }
                    }.frame(maxHeight: info.parts.count > 4 ? 220 : CGFloat(info.parts.count * 40))
                }
            }
            optionsCard
        }
    }
    private var optionsCard: some View {
        ContentCard {
            VStack(alignment: .leading, spacing: 19) {
                Text("下载偏好").font(.headline)
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("画质").font(.caption).foregroundStyle(.secondary)
                        Picker("画质", selection: $store.options.quality) {
                            if let playback = store.playback, !playback.qualities.isEmpty {
                                ForEach(playback.qualities, id: \.self) { quality in Text(playback.qualityName(quality)).tag(quality) }
                            } else { Text("自动选择可用画质").tag(store.options.quality) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("视频编码").font(.caption).foregroundStyle(.secondary)
                        Picker("视频编码", selection: $store.options.codec) {
                            Text("H.264 · 兼容优先").tag(7)
                            Text("HEVC · 体积更小").tag(12)
                            Text("AV1").tag(13)
                        }.labelsHidden().frame(maxWidth: .infinity).disabled(store.options.audioOnly)
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("音频").font(.caption).foregroundStyle(.secondary)
                        Picker("音频", selection: $store.options.audio) {
                            Text("标准").tag("标准")
                            if store.playback?.audios.contains(where: { $0.label == "FLAC" }) == true { Text("FLAC 无损").tag("FLAC") }
                            if store.playback?.audios.contains(where: { $0.label == "Dolby" }) == true { Text("Dolby").tag("Dolby") }
                        }.labelsHidden().frame(maxWidth: .infinity)
                    }
                }
                HStack(spacing: 22) {
                    Toggle("仅下载音频", isOn: $store.options.audioOnly)
                    Toggle("保留独立音频", isOn: $store.options.keepAudio).disabled(store.options.audioOnly)
                    Toggle("导出弹幕", isOn: $store.options.danmaku).help("导出原始 XML 和 ASS 字幕；高级弹幕保留在 XML 中")
                }.toggleStyle(.checkbox).font(.callout)
                Divider()
                HStack {
                    Button { store.chooseFolder() } label: {
                        Label(store.folder.abbreviatedPath, systemImage: "folder").font(.caption).lineLimit(1).truncationMode(.middle)
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help(store.folder.path)
                    Spacer(minLength: 20)
                    Button { store.enqueue() } label: { Label("下载 \(store.selectedParts.count) 个视频", systemImage: "arrow.down") }
                        .buttonStyle(.glassProminent).controlSize(.large).disabled(store.selectedParts.isEmpty || store.isResolving)
                }
                Text("实际画质与音轨以各分集的账号权限和可用资源为准。未提供所选编码时自动使用可用编码。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

extension URL { var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath } }

struct QueueView: View {
    @EnvironmentObject var store: AppStore
    var completed: Bool
    private var items: [DownloadItem] {
        (completed ? store.completed : store.unfinished).filter { store.queueFilter.isEmpty || $0.title.localizedCaseInsensitiveContains(store.queueFilter) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(completed ? "每一份喜欢，都在这里。" : "正在收藏你的喜欢。").font(.system(size: 26, weight: .bold)).tracking(-0.5)
                    Text(completed ? "已保存 \(store.completed.count) 个视频" : "\(store.unfinished.count) 个任务 · 同时下载 \(store.parallelism) 个")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !completed && !store.unfinished.isEmpty {
                    Button("全部暂停", systemImage: "pause") { store.pauseAll() }.buttonStyle(.glass)
                    Button("全部继续", systemImage: "play") { store.resumeAll() }.buttonStyle(.glass)
                }
            }
            if items.isEmpty {
                ContentUnavailableView {
                    Label(completed ? "收藏，从第一个视频开始" : "还没有下载任务", systemImage: completed ? "play.rectangle.on.rectangle" : "arrow.down.circle.dotted")
                } description: {
                    Text(store.queueFilter.isEmpty ? "添加一个喜欢的视频，把它留在你的 Mac。" : "没有找到匹配的任务。")
                } actions: {
                    Button("添加视频", systemImage: "plus") { store.newDownload() }.buttonStyle(.glassProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) { ForEach(items) { item in DownloadRow(item: item) } }.padding(.bottom, 10)
                }
            }
        }.padding(32)
        .searchable(text: $store.queueFilter, prompt: "搜索下载记录")
    }
}

struct DownloadRow: View {
    @EnvironmentObject var store: AppStore
    let item: DownloadItem
    @State private var confirmRemoval = false
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(url: item.cover, width: 112, height: 72)
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    Spacer()
                    Text(item.state.title).font(.caption).foregroundStyle(statusColor)
                }
                if item.state != .completed {
                    ProgressView(value: item.progress).tint(statusColor)
                }
                HStack {
                    Text(item.detail).font(.caption).foregroundStyle(item.state == .failed ? .red : .secondary).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    if item.state != .completed { Text("\(Int(item.progress * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
            }
            HStack(spacing: 9) {
                if item.state.active || item.state == .queued {
                    Button { store.pause(item.id) } label: { Image(systemName: "pause.fill") }.disabled(item.state == .merging).help("暂停下载")
                } else if item.state != .completed {
                    Button { store.resume(item.id) } label: { Image(systemName: item.state == .failed ? "arrow.clockwise" : "play.fill") }.help(item.state == .failed ? "重试下载" : "继续下载")
                }
                if item.state == .completed {
                    Button { store.reveal(item) } label: { Image(systemName: "folder") }.help("在 Finder 中显示")
                }
                Menu {
                    Button("在 Finder 中显示", systemImage: "folder") { store.reveal(item) }
                    if !item.state.active { Button("移除任务…", systemImage: "trash", role: .destructive) { confirmRemoval = true } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.buttonStyle(.borderless).foregroundStyle(.secondary).padding(.top, 4)
        }
        .padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.05)))
        .confirmationDialog("移除此任务？", isPresented: $confirmRemoval) {
            Button("移除任务", role: .destructive) { store.remove(item) }
        } message: { Text("下载记录与未完成的临时文件将被移除，已保存的视频会保留。") }
    }
    private var statusColor: Color {
        switch item.state { case .failed: return .red; case .completed: return .green; case .paused, .queued: return .secondary; default: return .biliPink }
    }
}

struct PreferencesView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        Form {
            Section {
                LabeledContent("下载位置") {
                    HStack {
                        Text(store.folder.abbreviatedPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("选择…") { store.chooseFolder() }
                    }
                }
                Picker("同时下载", selection: $store.parallelism) {
                    ForEach(1...4, id: \.self) { Text("\($0) 个任务").tag($0) }
                }
                Picker("每个文件的连接数", selection: $store.connections) {
                    ForEach([1, 2, 4, 8], id: \.self) { Text($0 == 1 ? "单连接" : "\($0) 个连接").tag($0) }
                }
                Text("大文件自动分段并发下载；不支持安全分段的服务器会回退为单连接。设置对新建任务生效。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("下载", systemImage: "arrow.down.circle") }
            Section {
                LabeledContent("FFmpeg") {
                    HStack {
                        Image(systemName: store.ffmpeg == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(store.ffmpeg == nil ? .orange : .green)
                        Text(store.ffmpeg == nil ? "未找到" : store.ffmpeg == FFmpeg.bundledURL ? "已内置" : "自定义工具").foregroundStyle(.secondary)
                        Button("选择…") { store.chooseFFmpeg() }
                    }
                }
                if let binary = store.ffmpeg { Text(binary.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                else { Text("内置媒体工具缺失，请重新安装完整 App，或手动选择 FFmpeg。").font(.caption).foregroundStyle(.secondary) }
                Text("App 内置 FFmpeg，无需另行安装。仅用于本地音视频无损合并，LGPL 2.1 或更新版本许可；对应源码和构建说明随 App 附带。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("媒体工具", systemImage: "waveform") }
            Section {
                Picker("外观", selection: $store.appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
            } header: { Label("外观", systemImage: "circle.lefthalf.filled") }
            Section {
                LabeledContent("哔哩哔哩账号") {
                    if let account = store.accountName {
                        Text(account).foregroundStyle(.secondary)
                        Button("退出登录") { store.logout() }
                    } else { Button("扫码登录") { store.startLogin() } }
                }
                Text("使用哔哩哔哩 App 扫码。账号权限决定可下载的内容与画质，登录凭据由 macOS 钥匙串保护。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label("账号", systemImage: "person.crop.circle") }
            Section {
                HStack(spacing: 16) {
                    BrandMark(size: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BiliDownloader for Mac").font(.headline)
                        Text("1.0.1 · SwiftUI / Liquid Glass").font(.caption).foregroundStyle(.secondary)
                        Link("基于 Majjcom/BiliDownloader · MIT 许可", destination: URL(string: "https://github.com/Majjcom/BiliDownloader")!).font(.caption)
                    }
                    Spacer()
                }.padding(.vertical, 5)
            } header: { Text("关于") }
        }
        .formStyle(.grouped)
        .onChange(of: store.parallelism) { store.savePreferences() }
        .onChange(of: store.connections) { store.savePreferences() }
        .onChange(of: store.appearance) { store.savePreferences() }
    }
}

struct LoginView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button { store.showLogin = false } label: { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.tertiary) }.buttonStyle(.plain).help("关闭登录")
            }
            BrandMark(size: 48)
            VStack(spacing: 7) {
                Text("登录哔哩哔哩").font(.system(size: 24, weight: .bold))
                Text("解锁账号可用的更多画质").font(.callout).foregroundStyle(.secondary)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(.white)
                if let image = store.qrImage {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(16).opacity(store.qrExpired ? 0.15 : 1)
                } else if !store.qrExpired { ProgressView() }
                if store.qrExpired {
                    Button("刷新二维码", systemImage: "arrow.clockwise") { store.refreshQR() }.buttonStyle(.glassProminent)
                }
            }.frame(width: 240, height: 240)
            Text(store.qrStatus).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 310)
            if !store.qrExpired { Button("刷新二维码") { store.refreshQR() }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.biliPink) }
            Label("登录凭据安全存入 macOS 钥匙串", systemImage: "lock.shield").font(.caption).foregroundStyle(.tertiary)
        }.padding(24).padding(.bottom, 12).frame(width: 390)
    }
}
