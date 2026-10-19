import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task { await store.shutDown(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

@main
struct BiliMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore(preview: ProcessInfo.processInfo.arguments.contains("--preview"))
    var body: some Scene {
        WindowGroup("BiliDownloader", id: "main") {
            RootView().environmentObject(store)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1120, height: 780)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建下载") { store.newDownload() }.keyboardShortcut("n")
                Button("粘贴链接并新建") { store.newDownload(paste: true) }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.section = .settings }.keyboardShortcut(",")
            }
            CommandMenu("下载") {
                Button("解析视频") { store.resolve() }.keyboardShortcut(.return, modifiers: [.command]).disabled(store.isResolving || store.input.isEmpty)
                Divider()
                Button("全部暂停") { store.pauseAll() }
                Button("全部继续") { store.resumeAll() }
                Divider()
                Button("打开下载文件夹") { store.openFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Link("BiliDownloader 项目", destination: URL(string: "https://github.com/Majjcom/BiliDownloader")!)
            }
        }
    }
}
