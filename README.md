# PhoneBridge

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](https://www.apple.com/macos/)

PhoneBridge 是一款个人使用的 macOS 手机文件传输与投屏工具。主界面左侧为 Mac 文件区，右侧可按连接顺序展开多个手机文件面板；投屏区默认隐藏，点击设备面板中的“投屏”后才会从最右侧展开。手机文件可以拖到 Mac，Mac 文件也可以直接拖到 Android 或 iPhone 面板。

版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 当前 MVP 能力

- 原生 SwiftUI 多面板界面：Mac 文件、多个手机文件面板和按需展开的独立投屏侧栏。
- Mac 与每台手机文件面板分别支持独立横向滚动；缩小窗口或同时展开多个设备时，只滚动当前面板，不会带动其他设备。名称、大小、日期使用紧凑列宽，减少列表中央无效空白。
- Android / iPhone / iPad 按发现顺序加入界面；面板之间可拖动排序，分隔线可调整宽度。
- 浏览 Mac 文件夹。
- Android：浏览 `/sdcard` 路径中的目录、图片和视频；点击“照片 / 视频”可自动扫描常用媒体目录。
- Android：按需生成图片和视频缩略图，视频缩略图显示播放标识。
- iPhone/iPad：通过 macOS ImageCaptureCore 读取系统照片库中的图片和视频。
- iPhone/iPad：日期依次使用文件、EXIF、通用创建/修改日期和文件名时间；仍缺失时保留“—”，但可通过 PTP/目录顺序稳定排序。
- iPhone/iPad：按需加载图片和视频缩略图；视频缩略图显示播放标识。
- 手机侧支持照片/视频分类筛选、文件名搜索和当前结果全选。
- 每个手机文件都有明确的勾选框，可勾选多个文件后点击“传输到 Mac”。
- 勾选的多个文件也可以一起拖到 Mac；整个左侧面板是统一接收区，快速移动经过文件行或空白区都不会切换热区。
- 左侧单击文件可用默认应用打开；右键可选择“在 Finder 中显示”或“拷贝”。
- Mac 空白区域右键支持新建文件夹、新建空文件和粘贴 Finder 文件项目；同名粘贴自动保留为“副本”。
- 左侧右键可将文件或文件夹移到废纸篓，误删后仍可恢复。
- 自动记住最后访问的 Mac 文件夹，下次启动直接恢复。
- Mac 与 Android 顶部路径使用可点击面包屑，点击任意层级即可直接跳转。
- 点击双栏的名称、大小或日期表头，会刷新对应文件列表并切换升序或降序。
- 双栏支持按文件名即时搜索，并显示筛选结果数量。
- 遇到同名文件时提示选择“跳过 / 自动重命名 / 覆盖”，覆盖采用完成后替换，避免失败时破坏原文件。
- 显示逐文件传输百分比、预计剩余时间和当前速度；失败任务可直接点击“重试”。
- 手机文件落盘到 Mac 后，自动把文件修改时间更新为传输完成时间，便于按“日期”找到刚接收的文件；不修改 EXIF 或视频拍摄时间。
- Android 支持把 Mac 文件拖入当前手机目录；点击“传输到手机”时可在文件选择窗口中选择/输入具体 Android 目标文件夹，任务栏持续显示完整目标位置。
- iPhone 面板也支持“传输到手机”：PhoneBridge 生成一次性下载页，iPhone 下载后通过系统分享菜单选择“存储到文件”和具体目录；支持一次共享多个文件。
- 每台手机面板都提供“文本”：Android USB/ADB 会自动打开一次性本地页面，iPhone 可扫码进入；手机端可复制文本、调用系统分享保存到备忘录，完整 HTTP/HTTPS 地址还可直接打开。
- iPhone 支持选择 `.cer`、`.crt`、`.pem` 或 `.mobileconfig` 文件，通过带一次性令牌的本地网页和二维码下载 Charles CA；同时提供 iOS 安装与完全信任引导。
- 手机与 Mac 位于同一网络时，可扫描二维码打开无线传输页：手机可向 Mac 上传照片/视频，也可下载 Mac 共享的文件。
- Android 11 及以上支持系统二维码无线配对：在“无线连接”中生成二维码，用手机“无线调试 → 使用二维码配对设备”扫描后自动完成配对和连接；PhoneBridge 同时使用 ADB mDNS 与 macOS 原生 Bonjour 发现手机，并显示当前配对阶段和等待时间。公司网络把手机与 Mac 分配到不同子网时，只要首次扫码仍连接数据线且两个地址可互相访问，应用可经 USB 读取动态端口并完成加密配对。手动地址与 6 位配对码仍作为备用。无线文件浏览、传输及 scrcpy 投屏复用已有能力。
- 同一台 Android 同时通过 USB 和无线 ADB 接入时自动合并为一个设备，优先使用 USB 通道，避免重复文件面板和投屏窗口。
- iPhone 投屏支持“清晰优先 / 流畅优先 / 节省带宽”三档画质，并显示实际分辨率和帧率；还可启用带 PIN 的附近设备模式。
- iPhone AirPlay 接收名称可在“无线连接”中自定义并持久保存，支持中文；多人同时使用时可加入姓名、工位或设备编号，避免在“屏幕镜像”列表中混淆。
- 最右侧投屏栏默认隐藏，不再长期占用手机文件区；iPhone 可选“内嵌显示 / 独立窗口”，Android 固定使用 scrcpy 独立窗口。iPhone 无需登录 Apple ID，也不需要先插数据线即可从“无线连接”启动 AirPlay 接收器。
- Android 独立窗口保留低延迟、键鼠控制、剪贴板和拖放能力，避免内嵌采集造成的额外窗口与稳定性问题。
- 支持多台 Android 按设备并行启动 scrcpy；iPhone 同一时间只运行一个 AirPlay 接收器，切换到另一台 iPhone 时自动停止旧接收器再启动新会话，避免“屏幕镜像”列表出现多个同名 PhoneBridge。
- 投屏工具栏支持一键 PNG 截屏和 H.264 MP4 录屏；停止录制后可修改录像名称并选择 Mac 保存位置，窗口会自动记住上次使用的文件夹。取消保存时会在 PhoneBridge 主窗口二次确认，可返回保存或放弃并删除临时录像。iPhone 两种显示方式都直接保存接收到的原始投屏帧；Android 独立窗口使用 ScreenCaptureKit 采集对应窗口。

## 构建

文件传输部分只依赖 macOS 系统框架；iPhone AirPlay 投屏还依赖 UxPlay 和 GStreamer。建议安装完整 Xcode；当前构建脚本也兼容只安装 Command Line Tools 的环境。执行：

```bash
cd PhoneBridge
./scripts/build_app.sh
```

生成的应用位于：

```text
dist/PhoneBridge.app
```

日常使用建议把最终构建复制到固定路径 `/Applications/PhoneBridge.app`，并始终从“应用程序”启动。固定安装路径可避免 macOS 将不同构建位置识别成不同的屏幕录制授权对象。

也可以直接开发运行：

```bash
swift run PhoneBridge
```

## Android 准备

1. 安装 ADB：`brew install android-platform-tools`。
2. 在 Android 开发者选项中开启“USB 调试”。
3. 数据线连接后，在手机上允许这台 Mac 进行 USB 调试。
4. 执行 `adb devices -l` 应能看到状态为 `device` 的设备。

Android 投屏还需要安装 scrcpy：`brew install scrcpy`。PhoneBridge 会自动使用 `/opt/homebrew/bin/scrcpy` 或 `/usr/local/bin/scrcpy`。发布版 DMG 已内置 ADB 与 scrcpy，无需额外安装。

Android 11 及以上也可以打开“设置 → 开发者选项 → 无线调试”，在 PhoneBridge 的“无线连接”窗口中生成二维码，再点击手机的“使用二维码配对设备”扫码。PhoneBridge 会自动发现配对服务和连接端口。公司网络屏蔽 mDNS 或扫码不可用时，可展开“手动配对与连接”，分别填写配对地址、6 位配对码和连接地址；配对端口与连接端口通常不同。

PhoneBridge 会依次查找：

- `/opt/homebrew/bin/adb`
- `/usr/local/bin/adb`
- `~/Library/Android/sdk/platform-tools/adb`
- `/Library/Android/sdk/platform-tools/adb`

## iPhone / iPad 准备

1. 使用数据线连接设备。
2. 解锁设备。
3. 第一次连接时点击“信任此电脑”。
4. 如果照片使用“优化 iPhone 储存空间”，尚未下载到设备本地的原件可能不会立即出现。

iPhone 读取使用 Apple 自带的 ImageCaptureCore，不依赖越狱、私有框架或第三方守护进程。

iOS 不允许通过 ImageCaptureCore 任意写入照片库或文件系统。PhoneBridge 会把 Mac 文件放到带一次性令牌的本地下载页：在 iPhone 面板点击“传输到手机”或直接把 Mac 文件拖入面板，扫码后逐个下载，并在 iOS 分享菜单中选择保存目录。证书下载后仍需手动安装描述文件并开启完全信任。

iPhone 投屏使用 GPLv3 开源项目 UxPlay 接收 AirPlay。两种显示方式都通过 GStreamer 解码为 JPEG 图像流，再经本机 TCP 通道交给 PhoneBridge；内嵌模式显示在最右侧投屏栏，独立模式由 PhoneBridge 原生窗口显示。开发环境会自动查找 `/opt/homebrew/bin/uxplay` 或对应的 `/usr/local/bin` 路径；DMG 发布版内置 UxPlay 与所需组件。两种方式都不需要屏幕录制权限。

安装 UxPlay：

```bash
brew install cmake pkg-config libplist openssl@3 gstreamer
git clone https://github.com/FDH2/UxPlay.git
cd UxPlay
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/homebrew
cmake --build build
cmake --install build --prefix /opt/homebrew
```

开始投屏时直接打开“无线连接 → iPhone AirPlay 投屏（名称与启动）”：在显眼的名称框中修改接收名称，选择内嵌或独立窗口，然后点击“启动 iPhone 接收器”。此入口不依赖 USB iPhone 文件发现。普通模式要求 Mac 与 iPhone 位于可互相发现的局域网；没有共同 Wi-Fi 时，可启用附近设备投屏（AWDL）并输入界面 PIN。该模式依赖 Mac 与 iPhone 的 Wi-Fi/蓝牙，不是纯 USB 视频通道。

## 制作自包含 DMG（Apple Silicon）

```bash
./scripts/package_dmg.sh
```

脚本会构建应用、封装 UxPlay/GStreamer 和 scrcpy/ADB、重写动态库路径、执行签名检查，并在 `dist/` 下生成无需 Homebrew 的 Apple Silicon DMG。

## GitHub 自动发布

仓库通过 [`.github/workflows/release.yml`](.github/workflows/release.yml) 自动构建 Release：

1. 在 `Resources/Info.plist` 中递增版本号和 Build。
2. 在 `CHANGELOG.md` 顶部增加对应版本记录。
3. 提交并推送到 `main`。
4. GitHub Actions 先执行 Release 编译；如果 `v<版本号>` 尚未发布，则自动构建 UxPlay、下载并校验官方 scrcpy、生成自包含 DMG、创建标签和 GitHub Release。

若该版本已经存在，普通推送只做编译检查，不会重复覆盖 Release。需要重新生成同版本安装包时，可在 GitHub 的 Actions 页面手动运行 `Build and release`，并开启 `force_release`。

## 已知边界

- 拖拽目前发生在 PhoneBridge 左右面板之间，尚未实现直接拖到 Finder。
- Android 仅显示文件夹、图片和视频，其他文件会被过滤。
- iPhone 侧是按日期排序的平铺媒体列表，不展示 iOS 内部 DCIM 目录结构。
- iPhone AirPlay 可在内嵌侧栏与独立窗口之间切换；Android scrcpy 只使用独立窗口。
- 多台 Android 可同时保持投屏；iPhone 同一时间只保留一个 AirPlay 接收器，可在内嵌侧栏或独立窗口中显示。普通局域网模式通过所有可用局域网接口发布，兼容 Wi-Fi、有线和 USB 网卡；附近设备模式额外使用 AWDL。
- iPhone 普通 AirPlay 需要与 Mac 处于可互相发现的局域网；公司 Wi-Fi 若屏蔽 Bonjour/mDNS，设备可能无法出现。附近设备模式可绕开部分局域网限制，但仍受机型、系统版本和无线环境影响。
- iPhone 暂不支持由 Mac 静默写入任意系统目录；Mac 文件通过无线下载页交给 iOS，保存位置由用户在“存储到文件”中选择。
- 已使用真实 iPhone 和 Pixel 8a 验证媒体读取、缩略图、筛选、排序、传输与 Android scrcpy 独立窗口投屏；iPhone 断流进程回收、单接收器广播和不同网络环境仍需补充实机覆盖。

## 开源许可

PhoneBridge 自身源码采用 [GNU General Public License v3.0](LICENSE)。安装包还包含 UxPlay、GStreamer、FFmpeg、scrcpy 等第三方组件，各组件仍遵循其原始许可证；详情见 [THIRD_PARTY_NOTICES.txt](Resources/THIRD_PARTY_NOTICES.txt) 以及 DMG 内 `PhoneBridge.app/Contents/Resources/Licenses/`。
