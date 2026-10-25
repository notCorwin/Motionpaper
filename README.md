# Motionpaper

<img src="assets/AppIcon.png" width="160" alt="Motionpaper 流动纸带 M 图标">

[![Build and test](https://github.com/notCorwin/Motionpaper/actions/workflows/ci.yml/badge.svg)](https://github.com/notCorwin/Motionpaper/actions/workflows/ci.yml)

让 Mac 的航拍壁纸，一直动起来。

Motionpaper 是一个轻量的 macOS 菜单栏应用，通过系统原生壁纸框架，让已选用的航拍动态壁纸持续播放。启动即开始播放，退出即释放播放会话。

## 功能

- 使用 macOS 原生壁纸播放机制，无需自行导入视频。
- 以菜单栏应用运行，不显示 Dock 图标或主窗口。
- 流动纸带 M 图标在播放时轻微明暗流动，支持系统浅色、深色外观及减弱动态效果。
- 自动管理播放会话，避免重复获取，并在退出时释放资源。
- 仅依赖 Apple 系统框架，无第三方 Swift 包依赖。

## 系统要求

- **Apple Silicon Mac（arm64）**。
- **macOS 15.8.1，系统构建号 24H32**。虽然包声明的最低版本是 macOS 15，但当前实现会拒绝其他系统构建。
- 从源码构建需要 **Swift 6.1 或更高版本**及 macOS SDK，可通过 Xcode 或 Command Line Tools 提供。
- 在「系统设置 → 墙纸」中预先选择并下载可播放的系统航拍动态壁纸。

Motionpaper 使用私有的 `Wallpaper.framework` 及其 Swift ABI，因此兼容性取决于具体系统构建。升级系统后，可能需要更新框架绑定和构建号校验；构建成功不代表原生播放接口兼容。

可用以下命令确认本机环境：

```sh
sw_vers -productVersion
sw_vers -buildVersion
uname -m
swift --version
```

## 构建与运行

```sh
git clone https://github.com/notCorwin/Motionpaper.git
cd Motionpaper
sh scripts/build-app.sh release
open dist/Motionpaper.app
```

构建脚本会编译 arm64 可执行文件、生成应用图标，并将应用打包到 `dist/Motionpaper.app`，最后进行本地 ad hoc 签名。这不是 Developer ID 签名或公证发布包。

启动后，菜单栏出现纸带 M 图标并自动开始播放。点击图标，选择「退出 Motionpaper」即可结束播放会话。应用没有播放开关或壁纸选择器，壁纸由系统设置管理。

如果启动失败，菜单中会显示「无法开始播放，请退出后重新打开」，错误条目的提示信息包含具体原因。

也可以从 [GitHub Releases](https://github.com/notCorwin/Motionpaper/releases/latest) 下载 `Motionpaper-<提交前 12 位>.dmg`，打开后将 Motionpaper 拖入 Applications；运行限制与源码构建相同。菜单中的「检查更新…」可检查并下载最新提交的安装镜像，下载后会校验大小及 SHA-256。

## 开发与验证

运行核心播放逻辑测试：

```sh
swift test --parallel
```

现有测试覆盖重复启用、取消获取、过期异步结果释放及失败后重试。测试使用模拟会话，不验证私有系统框架的实际播放行为。

构建调试应用：

```sh
sh scripts/build-app.sh debug
open dist/Motionpaper.app
```

在受支持的系统上，先退出已运行的 Motionpaper，再运行内置 UI 验证：

```sh
MOTIONPAPER_VERIFICATION_DIRECTORY=/tmp/motionpaper-verification \
  dist/Motionpaper.app/Contents/MacOS/Motionpaper --verify-ui
```

此命令会启动真实播放会话，记录菜单状态和动画采样，保存浅色、深色图标截图，然后通过退出菜单动作关闭应用。检查输出目录的 `verification.json`：成功时 `phase` 为 `terminated`，`shutdownState` 为 `disabled`；失败时会包含 `error`。

[GitHub Actions 工作流](.github/workflows/ci.yml) 在主分支推送和拉取请求中运行核心测试、构建应用，并为主分支最新提交打包及发布 DMG；真实系统播放和 UI 验证需要在兼容的 Mac 桌面会话中执行。

## 项目结构

| 路径 | 用途 |
| --- | --- |
| [Sources/PlaybackCore](Sources/PlaybackCore) | 播放状态、异步获取与会话生命周期管理 |
| [Sources/Motionpaper](Sources/Motionpaper) | AppKit 应用入口、菜单栏、原生壁纸绑定与调试验证 |
| [Tests/PlaybackCoreTests](Tests/PlaybackCoreTests) | 核心播放逻辑测试 |
| [Support](Support) | 应用元数据与 arm64 私有框架链接存根 |
| [assets/AppIcon.png](assets/AppIcon.png) | 透明背景纸带 M 品牌源图 |
| [Tools/GenerateIcon.swift](Tools/GenerateIcon.swift) | 从品牌源图生成 App 图标及菜单栏单色标识 |
| [scripts/build-app.sh](scripts/build-app.sh) | 应用编译、打包与本地签名 |

## 获取帮助

请通过 [GitHub Issues](https://github.com/notCorwin/Motionpaper/issues) 报告问题或提出功能建议。报告播放问题时，请附上 macOS 版本、系统构建号、芯片架构、所选壁纸和错误提示；开发环境问题请同时提供 Swift 版本及相关构建输出。

## 维护与贡献

项目由 [notCorwin](https://github.com/notCorwin) 维护，欢迎通过 Issue 讨论或提交拉取请求。

贡献前请阅读相关源码，保持实现简洁，针对核心行为变更补充必要测试，并运行 `swift test --parallel` 和 `sh scripts/build-app.sh release`。涉及私有框架、菜单栏或播放行为的修改，还应在目标系统上验证实际行为，并在拉取请求中说明验证环境与结果。
