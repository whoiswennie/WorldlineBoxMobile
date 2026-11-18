# 世界线盒子 Android 客户端

WorldlineBox Mobile `0.1.3` 是[世界线盒子桌面版](https://github.com/whoiswennie/WorldlineBox)的 Android 伙伴客户端。扫码后，手机通过 SSH 连接运行中的电脑，使用现有伙伴、话题、任务与附件。DSH 和伙伴数据保留在电脑上。

[下载 Android 0.1.3 APK](https://github.com/whoiswennie/WorldlineBoxMobile/releases/tag/0.1.3) · [下载 Windows 0.1.3 安装包](https://github.com/whoiswennie/WorldlineBox/releases/tag/0.1.3) · [桌面端安装与使用教程](https://github.com/whoiswennie/WorldlineBox#首次使用和扫码连接)

- 聊天支持流式回复、执行阶段、复制、引用和朗读。手机支持录音转文字，识别结果进入输入框供编辑。
- 竖屏桌宠通话支持导入背景和 DeepSeek 流式语音。安装包内置大肥鱼（DeepSeek-chan）和月见八千代的 Live2D。与桌面版配对后，进入对应伙伴的桌宠会面即可加载自己的模型，播放中的语音可以驱动口型。
- 手机缓存近期会话及本机待发消息。连接恢复时重试待发消息，并从已确认的上传位置继续传文件。

## 消息与附件

首页的版本号来自当前安装包。会话列表按伙伴统计未读消息。在其他聊天里收到回复时可点「查看」切换。电脑「设置 → 手机连接 → 已配对设备」显示在线状态，找到本机后开启「信息推送」，并允许 Android 通知。后台连接会在通知栏显示，点击伙伴消息即可回到对应聊天。系统的勿扰或省电设置可能影响提醒，强行停止 App 后需再次打开。

搭配新版电脑端，每个附件最多 4 GiB。手机按网速调整分段，断线后继续传已选文件。电脑保留未完成的分段 24 小时；手机重启后，原文件仍在本机时可继续。上传完的附件回到该会话的输入框，确认后发送。大文件可以下载原件，用作任务输入。

## 语音

在桌面「设置 → 全局模型」中保存官方 `https://api.deepseek.com` 配置和 API Key。当前聊天可以继续使用已配置的模型。语音服务使用桌面保存的 DeepSeek 官方凭据，手机通过已配对的 SSH 连接发起请求。

点击伙伴消息下方的扬声器即可朗读整条消息。桌宠通话按对话段使用 WebSocket 流式合成。两种模式都使用 Stella。支持压缩的桌面端会用 gzip 无损转发音频。Android 缓冲约一秒音频后开始播放，较短的片段在接收完毕后立即播放。手机在聊天中点麦克风开始录音，再点一次将录音转成可编辑文字。首次使用时 Android 会请求麦克风权限。[DeepSeek 语音合成](https://api-docs.deepseek.com/zh-cn/guides/tts) · [DeepSeek 语音识别](https://api-docs.deepseek.com/zh-cn/guides/asr)

## 开发与打包

在项目目录运行三个 Windows 脚本。SDK 装在项目的 `.tools` 下。

| 脚本 | 用法 |
| --- | --- |
| `01-Setup-Environment.bat` | 下载项目固定版本 Flutter、JDK 和 Android SDK，交互确认 Android SDK 许可，再解析依赖。传 `-Update` 刷新项目固定的工具链。 |
| `02-Start-Development.bat` | 用已授权的 USB 调试设备或运行中的 Android 模拟器启动 Flutter 调试版。没有设备时自动打开本项目已配置的 `WorldlineBoxTest` 模拟器。自动选中的 `WorldlineBoxTest` 若以无窗口模式运行，脚本会重启它并打开窗口。使用 `-Device <id>` 可指定设备或继续使用无窗口模拟器。启动后终端会保持打开，用于日志和热重载。 |
| `03-Build-APK.bat` | 打包可侧载的调试 APK，输出到 `dist/WorldlineBoxMobile-debug.apk`。有自己的签名配置时传 `-Release`。 |

三个脚本均支持 `-Proxy http://127.0.0.1:7897`。发布签名使用本地的 `android/key.properties`，包含 `storeFile`、`storePassword`、`keyAlias` 和 `keyPassword`。Windows 环境交付 Android APK，iOS 构建需要 macOS 和相应签名环境。

从源码运行开发或打包脚本时，保留相邻的 `WorldlineBox` 桌面仓库并安装其 Node 依赖。构建直接使用此仓库内的两款授权模型，首次克隆后运行 Git LFS 拉取模型及贴图。桌面仓库的授权模型更新后，可运行 `node scripts/stage-pet-models.mjs` 同步 Android 资源。

GitHub Release 的 APK 使用发布签名。曾安装过调试版时，Android 可能要求先卸载调试版再安装，此操作会清除本机配对及缓存，需重新扫码。

## 扫码连接

1. 安装 Windows x64 版 WorldlineBox，在启动器选择共享 DSH 实例，在「设置 → 全局模型」配置聊天模型。先在电脑验证一次伙伴回复。
2. 电脑打开「设置 → 手机连接」，点「显示配对二维码」。手机从 Release 下载并安装 `WorldlineBoxMobile.apk`，打开 App 扫码。手机保存电脑指纹及授权。回家时优先局域网直连，出门后自动尝试远程地址。
3. 打开伙伴聊天，发送文字或通过「＋」选择文件。伙伴在电脑完成后，可在手机打开或保存交付的附件。电脑端可以暂停设备、允许重连或撤销授权。撤销后需要重新扫码。

从源码启动电脑端时，使用相邻 `WorldlineBox` 项目中的 `02-Start-Development.bat`。也可以用该项目的 Windows 安装器 `out/make/inno/WorldlineBoxSetup.exe` 更新桌面端。

手机安装「世界线盒子」。家中电脑无需公网 IP、端口映射或 VPN 客户端。电脑上的 WorldlineBox 需保持运行。在允许设备互访的家庭 Wi-Fi 或有线局域网中，App 自动发现电脑的新地址，双方重启后可直接重连。Windows 防火墙需要允许该应用在专用网络上通信。访客 Wi-Fi 隔离可能阻止直连。公网入口转发端到端加密的 SSH 流量。Cloudflare Quick Tunnel 用于临时联调，重启后会换地址。外地连接不上时，在手机的设备菜单「我的电脑 → 扫码更新地址」扫描电脑的新二维码，也可从相册选择。已有设备授权和局域网连接都会保留。固定公网地址可按下文配置。

[Cloudflare Quick Tunnel 说明](https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/)

## 固定公网入口

部署方为每台接入的电脑准备一个 Cloudflare 托管隧道和对应的 HTTPS 域名，将该域名的 HTTP 源站指向 `http://127.0.0.1:47833`。把域名设为桌面进程环境变量 `WORLDLINEBOX_MOBILE_TUNNEL_HOSTNAME`，隧道运行凭据通过部署密钥配置注入 `WORLDLINEBOX_MOBILE_TUNNEL_TOKEN`。用户的手机仍在桌面设置中扫一次码。保留同一域名、电脑端配对数据及主机密钥时，重启后可使用已保存的配对。公网入口应允许 App 发起 WebSocket，设备授权由桌面端 SSH 处理。

[Cloudflare 托管隧道部署说明](https://developers.cloudflare.com/tunnel/get-started/)

启用固定入口后，电脑端会在网络组件退出或启动失败时自动重试。服务恢复后，App 使用原配对重新连接。

## 验收

- 用手机关闭 Wi‑Fi，打开一个已存在的伙伴话题。发送文字及 CSV，让伙伴处理后交付结果文件。
- 在电脑端观察同一话题及进度。手机断开网络时让电脑继续执行，重连后从同一话题打开结果并保存，核对文件。
- 在手机会话中查看实时正文、执行阶段和附件。滚动后用「回到最新」返回。
- 用伙伴原生提问验证手机答复，用执行中消息验证引导、停止与继续。修改手机保存的主机指纹后应无法认证。
- 目前移动上传每个文件上限 200 MiB。桌面标记为外部引用的文件需先由伙伴交付为可下载附件。

可从伙伴列表清理本地显示缓存。清理缓存保留扫码配对和未送达队列。

电脑和手机通过「我的资料」编辑同一个姓名及个人介绍。手机扫码配对成功后通过 SSH 获取这些资料。电脑聊天里的来源标签和筛选使用设备的配对编号。

聊天和桌宠通话的输入框上方都可新建或切换话题，并由电脑端 DSH 压缩当前伙伴在该话题的上下文。群聊可以选择要压缩的伙伴。

「桌宠通话」使用桌面伙伴会面会话。手机内置与电脑相同的两段通话铃声，大肥鱼使用《Let Me Go》，其他伙伴使用菲比铃声。背景支持导入，也可使用随 App 提供的湖畔蓝调、雨中花房和秋日书房。

## 本地协议测试

桌面仓库运行 `node scripts/run-vitest-with-electron.mjs run --config vitest.config.ts tests/unit/bot-mobile-gateway.test.ts`，验证真实伙伴服务和媒体库的移动输入、请求去重及产物下载。手机仓库可运行 `flutter analyze` 和 `flutter test`。要一起测试 SSH，将 Python 环境中的 Paramiko 准备好，在一个终端运行 `python scripts/ssh-test-fixture.py`，另一终端把 `WORLDLINEBOX_SSH_TEST_FIXTURE` 指向它打印的配置路径，再运行 Flutter 测试。测试凭据仅用于本机隔离服务。

## 素材与第三方组件

随源码提供的三张通话背景为项目生成素材。通话铃声和角色头像沿用桌面版资源。[桌面项目第三方声明](https://github.com/whoiswennie/WorldlineBox/blob/main/THIRD_PARTY_NOTICES.md)。Live2D 查看器包含 SoulLink Emotion、PixiJS 和 pixi-live2d-display，原始许可证见 [`licenses`](licenses/)。

大肥鱼（DeepSeek-chan）的原画及拆分为神宫凉子，Live2D 建模为霓虹猫_NeonNeko。月见八千代使用雪熊企划授权随世界线项目分发的模型。 [大肥鱼模型使用须知](android/app/src/bundled/assets/pet-models/dafeiyu/license.txt) · [八千代分发许可](android/app/src/bundled/assets/pet-models/yachiyo/license.txt)
