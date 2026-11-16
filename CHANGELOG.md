# WorldlineBox Mobile 更新记录

## 0.1.1 · Android

从下载区取得发布签名的 `WorldlineBoxMobile.apk` 和对应的 `WorldlineBoxMobile.apk.sha256`。本次版本号为 `0.1.1`，Android 内部版本号为 `5`，支持 Android 7.0 及以上。

### 桌宠通话

- 重新设计竖屏会面输入区，将话题、上下文压缩、文字输入和通话操作放在独立的两行。收起后可从右下角头像恢复，背景与角色位置保持稳定。
- 对话气泡限制高度，长回复自动分页。首次出现回复时，执行进度、停止按钮和分页控件可以在气泡内完整显示。支持回看、重播、收起对白和查看完整对话。
- 与 [Windows 0.1.1](https://github.com/whoiswennie/WorldlineBox/releases/tag/0.1.1) 配对后，桌宠按当前页请求 DeepSeek 语音。该页播完再自动推进。连接旧版电脑时使用旧版语音接口。
- 改进 Android 音频缓冲、播放结束等待和停止后的清理，降低网络间隙、短语音和快速切页时的播放问题。
- Android 和 Windows 安装包都内置 CC0 授权的 Arch-chan Live2D 模型。进入大肥鱼的桌宠会面即可使用，无需手动下载或导入模型。APK 同时包含内置通话背景。 [Arch-chan 模型与授权](https://github.com/Speykious/arch-chan)

### 开发与升级

- Windows 开发脚本等待设备完成启动及 ADB 属性可读，再运行 Flutter。没有设备时可自动打开已配置的项目模拟器，启动完成后终端继续显示热重载和日志。
- 从 0.1.0 的正式 APK 可使用相同签名覆盖更新。曾安装私人调试 APK 的设备可能需要先卸载调试版，卸载会清除本机配对及缓存。
- 手机沿用电脑端的伙伴、话题与模型配置。新版语音分页和交互体验推荐搭配同版本桌面端。

[查看从 0.1.0 起的代码差异](https://github.com/whoiswennie/WorldlineBoxMobile/compare/0.1.0...0.1.1)
