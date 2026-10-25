# Motionpaper

<img src="assets/AppIcon.png" width="160" alt="Motionpaper 流动纸带 M 图标">

[![Build and release](https://github.com/notCorwin/Motionpaper/actions/workflows/ci.yml/badge.svg)](https://github.com/notCorwin/Motionpaper/actions/workflows/ci.yml)

让 Mac 的动态壁纸，一直动起来。

Motionpaper 是一个轻量的 macOS 菜单栏应用，通过系统原生壁纸框架，让当前选用的动态壁纸持续播放。打开应用即开始播放，退出时释放播放会话，壁纸仍由系统设置管理。

## 功能

- **原生播放**：使用 macOS 自带的壁纸播放机制，无需导入视频。
- **菜单栏运行**：没有主窗口和 Dock 图标，播放状态通过纸带 M 图标呈现。
- **适配系统外观**：菜单栏图标支持浅色、深色外观，并遵循系统的减弱动态效果设置。
- **检查更新**：启动时及每六小时检查新版本，也可从菜单手动检查；下载的安装镜像会校验大小与 SHA-256，并复用已通过校验的本地文件。
- **精简依赖**：使用 Swift 和 Apple 系统框架，没有第三方 Swift 包依赖。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 芯片 | Apple Silicon（arm64） |
| 系统 | macOS 15.8.1，构建号 **24H32** |
| 壁纸 | 在「系统设置 → 墙纸」中选用并下载支持播放的系统动态壁纸 |
| 源码构建 | Swift 6.1 或更高版本，以及 macOS SDK（由 Xcode 或 Command Line Tools 提供） |

应用使用私有的 `Wallpaper.framework` 及其 Swift ABI。尽管 Swift 包声明最低支持 macOS 15，当前实现会拒绝构建号不是 `24H32` 的系统；升级系统后的兼容性需要重新验证。

可在终端检查系统版本、构建号及芯片架构：

```sh
sw_vers -productVersion
sw_vers -buildVersion
uname -m
```

## 安装与使用

1. 从 [GitHub Releases](https://github.com/notCorwin/Motionpaper/releases/latest) 下载 `Motionpaper-<提交前 12 位>.dmg`。
2. 打开镜像，将 Motionpaper 拖入 Applications。
3. 在「系统设置 → 墙纸」中选择并下载支持播放的动态壁纸。
4. 打开 Motionpaper，菜单栏出现纸带 M 图标后自动开始播放。

点击菜单栏图标可选择「检查更新…」或「退出 Motionpaper」。发现更新后，应用会下载、校验并打开安装镜像；退出应用后，将新版本拖入 Applications 替换，再重新打开即可。

应用没有壁纸选择器或播放开关。要更换壁纸，请使用系统设置；要结束持续播放，请退出应用。如果菜单显示「无法开始播放，请退出后重新打开」，将鼠标停留在该条目上可查看具体错误。

构建脚本使用本地 ad hoc 签名，发布的安装包未使用 Developer ID 签名或经过 Apple 公证。

## 从源码构建

```sh
git clone https://github.com/notCorwin/Motionpaper.git
cd Motionpaper
sh scripts/build-app.sh release
open dist/Motionpaper.app
```

构建脚本会编译 arm64 可执行文件、生成图标、写入当前 Git 提交与更新地址，并将签名后的应用输出到 `dist/Motionpaper.app`。

需要调试版本时，将 `release` 替换为 `debug`。构建自己的安装镜像：

```sh
sh scripts/package-release.sh
```

## 开发与验证

运行核心逻辑测试：

```sh
swift test --parallel
```

测试覆盖播放会话的重复获取、取消、过期结果释放与失败重试，以及更新清单校验、提交比较、HTTP 错误处理和安装镜像缓存校验。测试使用模拟会话与本地网络替身，实际壁纸播放需要在受支持的 Mac 上验证。

在兼容系统的桌面会话中，先退出已运行的 Motionpaper，再执行内置 UI 验证：

```sh
sh scripts/build-app.sh debug
MOTIONPAPER_VERIFICATION_DIRECTORY=/tmp/motionpaper-verification \
  dist/Motionpaper.app/Contents/MacOS/Motionpaper --verify-ui
```

验证会启动真实播放会话、检查菜单动作、采样图标动画、保存浅色与深色图标截图，并通过退出菜单关闭应用。输出目录中的 `verification.json` 在成功时应包含 `phase: "terminated"` 和 `shutdownState: "disabled"`；失败时包含 `error`。

[GitHub Actions](.github/workflows/ci.yml) 负责运行测试和构建应用，并为默认分支的最新提交打包、发布 DMG。实际系统播放与 UI 验证需要在本地桌面会话中完成。

### 代码导航

| 路径 | 用途 |
| --- | --- |
| [Sources/Motionpaper](Sources/Motionpaper) | 应用入口、菜单栏、原生壁纸绑定、更新交互与 UI 验证 |
| [Sources/PlaybackCore](Sources/PlaybackCore) | 播放状态与异步会话生命周期 |
| [Sources/UpdateCore](Sources/UpdateCore) | 更新清单、下载与缓存校验 |
| [Tests](Tests) | 播放与更新核心逻辑测试 |
| [Support](Support) | 应用元数据与私有框架链接存根 |
| [Tools/GenerateIcon.swift](Tools/GenerateIcon.swift) | 从品牌源图生成应用与菜单栏图标 |
| [scripts](scripts) | 构建、安装镜像打包与发布脚本 |

## 获取帮助

通过 [GitHub Issues](https://github.com/notCorwin/Motionpaper/issues) 报告问题或提出建议。请附上 macOS 版本、系统构建号、芯片架构、所选壁纸和错误提示；构建问题请同时提供 Swift 版本与相关输出。

## 维护与贡献

项目由 [notCorwin](https://github.com/notCorwin) 维护，欢迎提交 Issue 或拉取请求。

贡献前请阅读相关源码，针对核心行为变更补充必要测试，并运行 `swift test --parallel` 和 `sh scripts/build-app.sh release`。涉及原生框架、菜单栏或播放行为的修改，还需在目标系统上验证，并在拉取请求中说明环境与结果。
