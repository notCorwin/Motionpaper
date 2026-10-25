# Motionpaper

<img src="assets/AppIcon.png" width="160" alt="Motionpaper 图标">

让 Mac 的动态壁纸，一直动起来。

Motionpaper 是一个 Mac 菜单栏小工具，用来让系统当前选中的动态壁纸持续播放。打开后自动工作，换壁纸仍在「系统设置」中完成。

[下载最新版](https://github.com/notCorwin/Motionpaper/releases/latest) · [反馈问题](https://github.com/notCorwin/Motionpaper/issues)

## 使用前确认

| 项目 | 适用范围 |
| --- | --- |
| 系统 | 面向 macOS 15、26 和 27 适配 |
| Mac | Apple 芯片 Mac；Intel Mac 可用于 macOS 15、26 |
| 壁纸 | macOS 自带、支持播放的动态壁纸，且已下载完成 |

安装包通用于 Apple 芯片和 Intel Mac，无需分别下载。可以从苹果菜单  →「关于本机」查看芯片和系统版本。

**各个历史系统小版本尚未全部实测。** 如果更新 macOS 后无法播放，请先检查 Motionpaper 是否有更新，或通过下方方式反馈。

## 安装与开始使用

1. 打开 [下载页面](https://github.com/notCorwin/Motionpaper/releases/latest)，在 **Assets（资源）** 中选择以 `.dmg` 结尾的安装包。
2. 打开安装包，把 **Motionpaper** 拖入 **应用程序（Applications）** 文件夹。
3. 在访达（Finder）侧边栏，点击安装磁盘旁的 ⏏ 按钮，将它推出。
4. 在「系统设置 → 墙纸」中选择支持播放的系统动态壁纸，并等待它下载完成。
5. 从「应用程序」打开 Motionpaper，在屏幕顶部菜单栏找到 **M 图标**。

Motionpaper 没有主窗口，也不会出现在程序坞（Dock）中。打开后，将鼠标停留在 M 图标上即可查看播放状态。

### 首次打开被系统拦截

当前安装包尚未经过 Apple 公证。如果提示无法验证开发者，确认安装包来自本项目的下载页面后，可按照 [Apple 官方指引](https://support.apple.com/zh-cn/102445)，在「系统设置 → 隐私与安全性」中选择「仍要打开」。

## 日常使用

| 想做什么 | 如何操作 |
| --- | --- |
| 查看播放状态 | 将鼠标停留在菜单栏的 M 图标上 |
| 更换壁纸 | 在「系统设置 → 墙纸」中选择另一张支持播放的动态壁纸 |
| 退出应用 | 点击 M 图标，选择「退出 Motionpaper」 |
| 下次使用 | 再次打开 Motionpaper，即会自动开始工作 |

## 更新应用

Motionpaper 会在启动时、以及运行期间每六小时自动检查更新。发现新版本后，M 图标的菜单中会出现「更新并重新启动…」。点击后，应用会下载、安装更新并重新打开。

也可以点击「检查更新…」手动检查，再按提示选择「更新并重新启动」或「稍后」。**只有在你选择更新后，才会开始下载和安装。**

请从本机的「应用程序」文件夹运行应用，再使用更新功能。如果自动更新失败，可退出 Motionpaper，重新下载最新版安装包，再将应用拖入「应用程序」替换旧版本。

## 遇到问题

### 壁纸没有动起来

1. 确认所选的是支持播放的系统动态壁纸，并且已经下载完成。
2. 将鼠标停留在 M 图标上查看状态。如果菜单显示「无法开始播放」，再将鼠标停留在该条目上查看具体原因。
3. 退出并重新打开 Motionpaper，或检查应用更新。

如果问题仍然存在，请通过 [GitHub Issues](https://github.com/notCorwin/Motionpaper/issues) 反馈。

### 反馈时提供哪些信息

请尽量附上以下信息，方便定位问题：

- macOS 版本和 Mac 芯片型号，可在「关于本机」中查看；
- 所选壁纸的名称；
- 出现问题前做了什么，例如更新系统、更换壁纸或更新应用；
- 错误提示的文字或截图。

## 维护与贡献

项目由 [notCorwin](https://github.com/notCorwin) 维护。欢迎通过 [Issues](https://github.com/notCorwin/Motionpaper/issues) 反馈使用体验、提出建议，也欢迎提交 Pull Request 改进应用与文档。

## 许可证

本项目采用 [GPLv3](LICENSE) 许可证。
