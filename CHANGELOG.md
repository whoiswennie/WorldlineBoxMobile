# WorldlineBox Mobile 更新记录

## 0.1.3 · Android

下载 `WorldlineBoxMobile.apk` 即可安装或覆盖升级。支持 Android 7.0 及以上，内部版本号为 8，沿用上一版发布签名。同页提供 SHA-256 校验文件。

本版 APK 已更新视频通话铃声：大肥鱼使用《Let Me Go》，其他伙伴使用菲比铃声。两段音频与 Windows 版相同，随 APK 安装。

- 手机启动页和会话首页统一使用「世界线盒子」，首页可查看当前安装版本。
- 扫码配对后，两台设备回到同一局域网时可以自动重连。异地远程地址变化后，重新扫描同一台电脑的二维码即可更新，已有局域网配对继续有效。
- 会话列表显示未读消息。在电脑的「设置 → 手机连接」为本机开启信息推送，并允许 Android 通知后，后台收到伙伴回复时可在通知栏查看摘要，点按即可进入对应聊天。
- 图片和文件单个最高支持 4 GiB。上传按网速调整分段，连接恢复后可以续传。电脑会保留未完成的分段 24 小时。

[下载配套 Windows 版](https://github.com/whoiswennie/WorldlineBox/releases/tag/0.1.3) · [查看代码差异](https://github.com/whoiswennie/WorldlineBoxMobile/compare/0.1.2...0.1.3)

## 0.1.2 · Android

本版 APK 的 Android 内部版本号为 **6**，支持 Android 7.0 及以上。使用与上一版相同的发布签名，可覆盖更新并保留配对和缓存。

- 大肥鱼在手机桌宠通话中使用与 Windows 0.1.2 相同的 DeepSeek-chan 模型，包含五张原始贴图、表情和动作。
- 新增月见八千代的内置 Live2D 和头像，与 Windows 0.1.2 使用同一份授权模型和两张原始贴图。连接桌面版后，选择月见八千代进入桌宠通话即可使用。
- 两款 Live2D 及许可都随 APK 安装。手机在本机加载模型，并按设备内存与图形能力调整贴图尺寸。打包时逐文件核对头像、模型、贴图、表情、动作和授权。
- Android 查看器使用新版 Live2D 渲染循环驱动模型与表演。桌面配对、会话和资料沿用现有设置。

[Windows 0.1.2](https://github.com/whoiswennie/WorldlineBox/releases/tag/0.1.2) · [查看手机版代码差异](https://github.com/whoiswennie/WorldlineBoxMobile/compare/0.1.1...0.1.2)

## 0.1.1 · Android

从下载区取得发布签名的 `WorldlineBoxMobile.apk` 和对应的 `WorldlineBoxMobile.apk.sha256`。本次版本号为 `0.1.1`，Android 内部版本号为 `5`，支持 Android 7.0 及以上。

### 桌宠通话

- 重新设计竖屏会面输入区，将话题、上下文压缩、文字输入和通话操作放在独立的两行。收起后可从右下角头像恢复，背景与角色位置保持稳定。
- 对话气泡限制高度，长回复自动分页。首次出现回复时，执行进度、停止按钮和分页控件可以在气泡内完整显示。支持回看、重播、收起对白和查看完整对话。
- 与 [Windows 0.1.1](https://github.com/whoiswennie/WorldlineBox/releases/tag/0.1.1) 配对后，桌宠按当前页请求 DeepSeek 语音。该页播完再自动推进。连接旧版电脑时使用旧版语音接口。
- 改进 Android 音频缓冲、播放结束等待和停止后的清理，降低网络间隙、短语音和快速切页时的播放问题。
- Android 和 Windows 安装包都经作者授权内置 DeepSeek-chan（大肥鱼）Live2D 模型。进入大肥鱼的桌宠会面即可使用。原画及拆分为神宫凉子，Live2D 建模为霓虹猫_NeonNeko，模型使用须知随安装包提供。APK 同时包含内置通话背景。

### 开发与升级

- Windows 开发脚本等待设备完成启动及 ADB 属性可读，再运行 Flutter。没有设备时可自动打开已配置的项目模拟器，启动完成后终端继续显示热重载和日志。
- 从 0.1.0 的正式 APK 可使用相同签名覆盖更新。曾安装私人调试 APK 的设备可能需要先卸载调试版，卸载会清除本机配对及缓存。
- 手机沿用电脑端的伙伴、话题与模型配置。新版语音分页和交互体验推荐搭配同版本桌面端。

[查看从 0.1.0 起的代码差异](https://github.com/whoiswennie/WorldlineBoxMobile/compare/0.1.0...0.1.1)
