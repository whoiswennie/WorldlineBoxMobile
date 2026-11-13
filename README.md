# 世界线盒子 · 手机端

WorldlineBox Mobile `0.1.0` 是[世界线盒子桌面版](https://github.com/whoiswennie/WorldlineBox)的 Android 伙伴客户端。扫码后，手机通过 SSH 连接运行中的电脑，使用现有伙伴、话题、任务与附件。DSH 和伙伴数据保留在电脑上。

- 聊天支持流式回复、执行阶段、复制、引用和朗读。手机支持录音转文字，识别结果进入输入框供编辑。
- 竖屏桌宠通话支持 Live2D、从手机导入背景和 DeepSeek 流式语音。角色口型按实际播放的音频驱动。
- 手机缓存近期会话及本机待发消息。连接恢复时重试待发消息，并从已确认的上传位置继续传文件。

## 语音

在桌面「设置 → 全局模型」中保存官方 `https://api.deepseek.com` 配置和 API Key。当前聊天可以继续使用已配置的模型。语音服务使用桌面保存的 DeepSeek 官方凭据，手机通过已配对的 SSH 连接发起请求。

点击伙伴消息下方的扬声器即可朗读整条消息。桌宠通话按对话段使用 WebSocket 流式合成。两种模式都使用 Stella。手机在聊天中点麦克风开始录音，再点一次将录音转成可编辑文字。首次使用时 Android 会请求麦克风权限。[DeepSeek 语音合成](https://api-docs.deepseek.com/zh-cn/guides/tts) · [DeepSeek 语音识别](https://api-docs.deepseek.com/zh-cn/guides/asr)

## 开发与打包

在项目目录运行三个 Windows 脚本。SDK 装在项目的 `.tools` 下。

| 脚本 | 用法 |
| --- | --- |
| `01-Setup-Environment.bat` | 下载项目固定版本 Flutter、JDK 和 Android SDK，交互确认 Android SDK 许可，再解析依赖。传 `-Update` 刷新项目固定的工具链。 |
| `02-Start-Development.bat` | 用 USB 调试设备或已启动的 Android 模拟器运行 Flutter 调试版。多个设备时传 `-Device <id>`。 |
| `03-Build-APK.bat` | 打包可侧载的调试 APK，输出到 `dist/WorldlineBoxMobile-debug.apk`。有自己的签名配置时传 `-Release`。 |

三个脚本均支持 `-Proxy http://127.0.0.1:7897`。发布签名使用本地的 `android/key.properties`，包含 `storeFile`、`storePassword`、`keyAlias` 和 `keyPassword`。Windows 环境交付 Android APK，iOS 构建需要 macOS 和相应签名环境。

从源码运行开发或打包脚本时，保留相邻的 `WorldlineBox` 桌面仓库并安装其 Node 依赖。打包私人测试 APK 前，在桌面仓库执行 `git lfs pull` 取得模型二进制。模型会由脚本从已有的本地文件打包进 APK。

## 扫码连接

1. 用更新后的 Windows x64 版 WorldlineBox 打开「设置 → 远程连接」，点「显示配对二维码」。Windows 安装包内置公网连接组件，开发版也可自动下载。
2. 手机安装 `dist/WorldlineBoxMobile-debug.apk`，打开 App，点「扫描二维码」。手机保存设备凭据，后续在入口可用期间会自动连接。
3. 电脑端可关闭服务、断开设备、允许重连或删除授权。删除后需要重新扫码。

从源码启动电脑端时，使用相邻 `WorldlineBox` 项目中的 `02-Start-Development.bat`。也可以用该项目的 Windows 安装器 `out/make/inno/WorldlineBoxSetup.exe` 更新桌面端。

手机只需要安装世界线盒子。家中电脑无需公网 IP、端口映射或 VPN 客户端。电脑上的 WorldlineBox 需保持运行。公网入口转发端到端加密的 SSH 流量。Cloudflare Quick Tunnel 用于临时联调，重启后会换地址。长期使用需要部署下文的固定公网入口。

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

「桌宠通话」使用桌面伙伴会面会话。拨号时沿用电脑端铃声，大肥鱼有专属铃声，其他伙伴使用通用铃声。未配置 Live2D 的伙伴显示原尺寸头像。私人测试 APK 可从相邻桌面仓库打包本地大肥鱼模型。模型原画及拆分为神宫凉子，Live2D 建模为霓虹猫_NeonNeko，公开发行需依据作者授权。贴图保留原尺寸，超出设备限制时生成适配版本。背景支持导入，也可使用随 App 提供的湖畔蓝调、雨中花房和秋日书房。

## 本地协议测试

桌面仓库运行 `node scripts/run-vitest-with-electron.mjs run --config vitest.config.ts tests/unit/bot-mobile-gateway.test.ts`，验证真实伙伴服务和媒体库的移动输入、请求去重及产物下载。手机仓库可运行 `flutter analyze` 和 `flutter test`。要一起测试 SSH，将 Python 环境中的 Paramiko 准备好，在一个终端运行 `python scripts/ssh-test-fixture.py`，另一终端把 `WORLDLINEBOX_SSH_TEST_FIXTURE` 指向它打印的配置路径，再运行 Flutter 测试。测试凭据仅用于本机隔离服务。

## 素材与第三方组件

随源码提供的三张通话背景为项目生成素材。角色头像沿用桌面项目美术，来源和授权范围见[桌面项目第三方声明](https://github.com/whoiswennie/WorldlineBox/blob/main/THIRD_PARTY_NOTICES.md)。Live2D 查看器包含 SoulLink Emotion、PixiJS 和 pixi-live2d-display，原始许可证见 [`licenses`](licenses/)。本地模型、Cubism Core、铃声、测试 APK 和签名凭据由各自的构建输入提供。
