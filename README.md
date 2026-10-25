# Motionpaper

<img src="assets/AppIcon.png" width="160" alt="Motionpaper 图标">

让 Mac 的动态壁纸，一直动起来。

Motionpaper 是一个 macOS 菜单栏小工具，让当前选用的系统动态壁纸持续播放。打开应用后自动开始，壁纸仍在系统设置中选择。

[下载最新版](https://github.com/notCorwin/Motionpaper/releases/latest) · [反馈问题](https://github.com/notCorwin/Motionpaper/issues)

## 安装前确认

当前版本的播放功能仅支持以下环境：

| 项目 | 要求 |
| --- | --- |
| Mac 芯片 | Apple Silicon（M 系列） |
| macOS | **15.8.1，构建号 24H32** |
| 壁纸 | macOS 自带、支持播放的动态壁纸，且已下载完成 |

可从苹果菜单打开「关于本机」查看 macOS 版本，点按版本号查看构建号，详见 [Apple 官方说明](https://support.apple.com/zh-cn/109033)。

**其他系统构建号目前无法开始播放。** 升级 macOS 后，请重新确认 Motionpaper 是否支持新系统。

## 安装与开始使用

1. 前往 [下载页面](https://github.com/notCorwin/Motionpaper/releases/latest)，在 **Assets（资源）** 中下载以 `.dmg` 结尾的安装包。
2. 打开安装包，将 **Motionpaper** 拖入 **应用程序（Applications）** 文件夹。
3. 在「系统设置 → 墙纸」中选择支持播放的系统动态壁纸，等待下载完成。
4. 推出安装镜像，再从「应用程序」打开 Motionpaper。
5. 屏幕顶部菜单栏出现 M 图标后，将鼠标停留在图标上；提示「Motionpaper：正在播放」即表示已开始播放。

当前安装包尚未经过 Apple 公证。如果首次打开时因无法验证开发者或未经过公证而被拦截，确认安装包来自本项目后，可按 [Apple 官方指引](https://support.apple.com/zh-cn/102445)，前往「系统设置 → 隐私与安全性」选择「仍要打开」。

## 日常使用

Motionpaper 常驻屏幕顶部菜单栏，没有主窗口，也不会显示在 Dock 中。

| 想做什么 | 如何操作 |
| --- | --- |
| 查看播放状态 | 将鼠标停留在菜单栏的 M 图标上 |
| 更换壁纸 | 在「系统设置 → 墙纸」中选择另一张支持播放的动态壁纸 |
| 停止持续播放 | 点击 M 图标，选择「退出 Motionpaper」 |
| 重新开始播放 | 再次打开 Motionpaper |

菜单栏图标会适配系统的浅色、深色外观。开启系统的「减弱动态效果」时，图标不会播放动画；可通过悬停提示确认播放状态。

## 更新应用

Motionpaper 会在启动时及运行期间每六小时检查一次更新。发现新版本后，菜单中会出现「更新并重新启动（版本标识）…」。点击后，应用会下载、校验并安装更新，然后自动重新启动。

也可以点击菜单中的「检查更新…」手动检查，在弹窗中选择「更新并重新启动」或「稍后」。**下载和安装会在你选择更新后开始。**

请从本机的「应用程序」文件夹运行 Motionpaper，并确保你有该文件夹的写入权限，以便应用完成更新。若提示无法自动更新，可退出应用，从 [下载页面](https://github.com/notCorwin/Motionpaper/releases/latest) 获取安装包，再拖入「应用程序」替换旧版本。

## 遇到问题

### 壁纸没有动起来

先确认系统版本和构建号符合上面的要求，并且所选壁纸支持播放、已经下载完成。

如果菜单中出现「无法开始播放，请退出后重新打开」，将鼠标停留在该条目上可查看具体原因，再退出并重新打开应用。

### 反馈问题或提出建议

请前往 [GitHub Issues](https://github.com/notCorwin/Motionpaper/issues)。报告播放或更新问题时，请附上：

- macOS 版本和系统构建号；
- Mac 芯片型号；
- 所选壁纸的名称；
- 问题出现前的操作，以及错误提示或截图。

## 维护与贡献

项目由 [notCorwin](https://github.com/notCorwin) 维护。欢迎通过 Issue 提出建议，或提交 Pull Request 改进应用与文档。

## 许可证

本项目采用 [GNU GPL v3.0](LICENSE) 许可证。
