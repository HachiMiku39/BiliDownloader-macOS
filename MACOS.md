# BiliDownloader for macOS

基于 [Majjcom/BiliDownloader](https://github.com/Majjcom/BiliDownloader) 的独立 macOS 适配，采用 SwiftUI 原生客户端。上游 Python / PySide6 源码保留在 `src/`，Mac 客户端位于 `macos/`；不需要 Python、Qt 或原项目的更新服务密钥。本适配并非上游官方发行版。

## 安装与使用

1. 打开 `BiliDownloader-macOS.dmg`，将 App 拖入“应用程序”。也可解压 `BiliDownloader-macOS.zip`，直接运行其中的 App。
2. App 已内置 FFmpeg，无需安装 Homebrew 或其他依赖。高级用户也可在“设置 → 媒体工具”中选择兼容的自定义 FFmpeg。
3. 粘贴 B 站链接或 BV / AV / EP / MD / SS 编号，点击“解析视频”。支持 `b23.tv` 短链接。
4. 勾选分集，选择画质、H.264 / HEVC / AV1 编码和下载文件夹，开始下载。
5. 在“下载队列”中暂停、继续或重试；在“已完成”中点击文件夹图标，用 Finder 查看文件。

本次二进制面向 **Apple Silicon（arm64）**，最低 macOS 26，按 macOS 27 的系统外观设计并在 macOS 27.2 上验证。未构建或验证 Intel 二进制。

App 使用本地临时签名，**没有 Developer ID 签名或 Apple 公证**。跨设备分发可能需要用户在“系统设置 → 隐私与安全性”中确认打开。正式公开发行应由发布者使用自己的 Developer ID 签名并公证；构建脚本不会读取证书或上传文件。

## 原生体验

- 系统 Liquid Glass 工具栏与按钮、半透明侧边栏、SF Symbols、系统字体和 Retina 显示。
- 外观跟随系统，也可单独选择浅色或深色；系统组件响应减少透明度等辅助功能设置。
- `⌘N` 新建，`⌘⇧N` 粘贴并新建，`⌘↩` 解析，`⌘,` 设置，`⌘⇧O` 打开下载文件夹。
- Finder 文件夹选择器；可将链接文本拖入主窗口。
- 1～4 个并发下载，默认 2 个。重新打开后，未完成任务暂停等待用户继续。
- 每个文件可使用 1 / 2 / 4 / 8 个连接，默认 4 个。大文件分段并发下载，完成分段会保留以便续传；服务器不提供强文件版本标识、不支持 Range，或响应范围/版本不一致时回退为完整单连接下载。小文件使用单连接。
- 使用 URLSession 的下载任务和 HTTP 验证信息续传，下载体不会一次性加载到内存。链接失效时刷新并重试；服务器不支持续传时重新下载。
- 下载中间文件位于所选目录下的 `.BiliDownloader-任务UUID`；合并成功才发布最终视频。暂停保留中间文件，移除任务清理中间文件，保留成品。
- FFmpeg 无损合并音视频；支持仅音频、保留独立音频、可用 FLAC / Dolby 音轨；XML 和 ASS 弹幕导出。ASS 支持普通滚动与顶部/底部固定弹幕，高级弹幕保留于 XML。
- 扫码登录使用原项目的 B 站接口，凭据存入 macOS 钥匙串；“退出登录”清除本机凭据。
- 下载记录存放在 `~/Library/Application Support/BiliDownloader/downloads.json`；默认下载到 `~/Downloads/BiliDownloader`。

可下载内容和画质受 B 站接口、地区和账号权限限制。没有所选编码或音轨时使用可用资源；清晰度降级会显示在完成状态中。明确返回试看的内容会拒绝入库，避免把试看当作完整视频。需要大会员或购买的内容仍需拥有相应权限；不支持受 DRM 保护内容。

## 从源码构建

安装 Xcode 26 或更新版本（推荐匹配 macOS 27 的 Xcode）及命令行工具，然后在仓库根目录执行：

```sh
./macos/scripts/build-app.sh
```

输出为 `macos/dist/BiliDownloader.app`、`macos/dist/BiliDownloader-macOS.zip` 和 `macos/dist/BiliDownloader-macOS.dmg`。构建脚本在全局选择 Command Line Tools 时会尝试本机已有 Xcode，不改变系统的 `xcode-select` 设置；可用 `DEVELOPER_DIR` 显式指定工具链。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./macos/scripts/build-app.sh
```

Swift 包没有第三方依赖。打包脚本从 FFmpeg 官方 GitHub 镜像下载固定的 n9.0.2 标签源码并校验 SHA-256，编译静态 FFmpeg 库，仅动态依赖 macOS 系统库。源码归档、许可证、校验和、配置参数及依赖列表会放入 App 的 `Contents/Resources/FFmpegSource/`。该 FFmpeg 专用于本地媒体无损合并，禁用网络协议、GPL、nonfree 和外部依赖。

也可以用 Xcode 打开 `macos/Package.swift` 继续开发。直接运行 Swift 包时尚无 App 资源，可通过 `BILIMAC_FFMPEG` 指定本地工具以便开发验证。

## 验证

运行完整测试需要 Python 3 和 FFmpeg（仅本机测试媒体生成使用）：

```sh
./macos/scripts/test.sh
```

XCTest 覆盖编号解析、与上游 Python 一致的 WBI 签名、接口错误、DASH/番剧结构与画质音轨回退、文件名和任务记录、弹幕转义、HTTP 403、暂停续传、分段并发上限、已完成分段复用、忽略或错误 Range / ETag 变化时的完整重下，以及真实 H.264 + AAC 下载和 FFmpeg 合并。网络传输测试使用本机临时 HTTP 服务和自行生成的测试媒体；运行结束自动清理。

本次还通过实际 App 验证了公开 B 站视频的解析与可用画质、扫码登录二维码生成，以及浅深色首页、设置页、队列入口。未使用个人账号完成扫码登录，付费/大会员和地区限制资源未端到端验证。

## 来源与许可

上游项目：[Majjcom/BiliDownloader](https://github.com/Majjcom/BiliDownloader)，源码获取日期为 2026-10-19。API 路径、WBI 算法和下载流程由其 Python 实现移植，MIT 许可见根目录 `LICENSE`。原 Windows / Linux 构建方式参见原始 `SETUP.md`。

设计参考：[Apple — Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)。原生系统控件随运行系统呈现对应外观，玻璃效果只用于导航及操作层。

分段并发设计参考：[Gopeed HTTP 下载实现](https://github.com/GopeedLab/gopeed/tree/5462b14705359ac081bab1b48dfeae330a0af0f5/internal/protocol/http)，参考快照为 `5462b14705359ac081bab1b48dfeae330a0af0f5`。Mac 版的固定分段工作队列、URLSession 任务、检查点文件和验证测试在 Swift 中独立实现。
