# WorldlineBox Mobile 更新记录

## 0.1.6 · Android

下载 `WorldlineBoxMobile.apk` 安装或覆盖升级。支持 Android 7.0 及以上，内部版本号为 12。下载页同时提供 SHA-256 校验文件。

- 在「附近的电脑」按名称选择同一局域网中的主机，首次配对时核对连接码并在电脑上同意。再次回到该网络时，手机可以自动重连。
- 点聊天输入框旁的「＋」即可拍照、录像，或按手机相册浏览和混选图片、视频。选好的附件可以和文字一起发送。
- 点开收到的附件即可放大图片、逐页查看 PDF 或阅读文本。再次查看时会复用手机上已缓存的原件，点保存按钮即可另存到手机。
- 进入会话时直接显示最新消息。发送普通消息时，聊天里正在播放的音乐或视频会继续，开始新的播放时再切换。

[下载配套 Windows 版](https://github.com/whoiswennie/WorldlineBox/releases/tag/0.1.9) · [查看代码差异](https://github.com/whoiswennie/WorldlineBoxMobile/compare/0.1.5...0.1.6)

## 0.1.5 · Android

下载 `WorldlineBoxMobile.apk` 安装或覆盖升级。支持 Android 7.0 及以上，内部版本号为 10，沿用上一版发布签名。同页提供 SHA-256 校验文件。

- 点会话首页右上角的「切换电脑」可添加或切换主机。手机分别保存每台电脑的聊天缓存、草稿和待发送消息。升级后会保留原有配对。
- 一台手机可保持与多台电脑的连接，一台电脑也能连接多部手机。「清理失效连接」会检查已撤销的配对和失效的临时远程地址。暂时离线的主机可以在恢复连接后继续使用。
- 与 Windows 0.1.6 配对后，音乐、视频等应用开关在同一聊天的各个话题中生效。任一端关闭应用后，旧卡片会提示重新启用。伙伴消息下方提供复制和朗读。

[下载配套 Windows 版](https://github.com/whoiswennie/WorldlineBox/releases/tag/0.1.6) · [查看代码差异](https://github.com/whoiswennie/WorldlineBoxMobile/compare/0.1.4...0.1.5)

## 0.1.4 · Android

下载 `WorldlineBoxMobile.apk` 即可安装或覆盖升级。支持 Android 7.0 及以上，内部版本号为 9，沿用上一版发布签名。同页提供 SHA-256 校验文件。

- 聊天中可查看伙伴分享的视频封面、标题、UP 主和音乐曲目。在卡片里播放视频、听歌或切换曲目。历史卡片点按后播放。视频支持全屏和返回原卡片，也可点「用哔哩哔哩打开」在已安装的客户端观看对应视频和分 P。
- 配对 Windows 0.1.5 后，点聊天右上角的「话题应用」可同时启用音乐、视频、浏览器、资产库和小屋世界。任一端的修改会同步到同一个话题，浏览器可从电脑已打开的标签页中选择。
- 手机在本机播放媒体，卡片里的视频采用哔哩哔哩官方嵌入播放器。可播放的内容与清晰度取决于平台提供的权限。

[下载配套 Windows 版](https://github.com/whoiswennie/WorldlineBox/releases/tag/0.1.5) · [查看代码差异](https://github.com/whoiswennie/WorldlineBoxMobile/compare/0.1.3...0.1.4)

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
