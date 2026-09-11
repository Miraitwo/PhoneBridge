import AppKit
import SwiftUI

struct FirstLaunchGuideView: View {
    let onFinish: () -> Void

    @State private var selectedPage = 0

    private let pages = FirstLaunchGuidePage.allCases

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.left.arrow.right.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("欢迎使用 PhoneBridge")
                        .font(.title2.bold())
                    Text("用几步了解文件传输、无线连接和投屏")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(24)

            Divider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            selectedPage = index
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: page.symbol)
                                    .frame(width: 20)
                                Text(page.title)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                selectedPage == index ? Color.accentColor.opacity(0.14) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .frame(width: 180)
                .padding(18)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))

                Divider()

                ScrollView {
                    pageContent(pages[selectedPage])
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                }
            }

            Divider()

            HStack {
                Button("稍后自己探索", action: onFinish)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("上一步") {
                    selectedPage = max(0, selectedPage - 1)
                }
                .disabled(selectedPage == 0)

                if selectedPage == pages.count - 1 {
                    Button("开始使用", action: onFinish)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("下一步") {
                        selectedPage = min(pages.count - 1, selectedPage + 1)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 740, height: 560)
    }

    @ViewBuilder
    private func pageContent(_ page: FirstLaunchGuidePage) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(page.title, systemImage: page.symbol)
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text(page.summary)
                .font(.title3)
                .foregroundStyle(.secondary)

            if page == .companyNetwork {
                CompanyNetworkModeGuideView()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(page.points.enumerated()), id: \.offset) { index, point in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Color.accentColor, in: Circle())
                            Text(point)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            }

            if let tip = page.tip {
                Label(tip, systemImage: "lightbulb.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

struct CompanyNetworkModeGuideView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("绕开公司 Wi-Fi 的终端隔离", systemImage: "building.2.crop.circle")
                .font(.headline)
            Text("让 Mac 使用有线或 USB 网卡连接公司网络，再由 Mac 创建独立 Wi-Fi 热点。iPhone 连接这个热点后，PhoneBridge 使用普通 AirPlay 投屏，不需要公司 Wi-Fi 允许设备互访。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                companyStep(1, "确认 Mac 已通过有线网卡或 USB 网卡接入公司网络。")
                companyStep(2, "打开“系统设置 → 通用 → 共享 → 互联网共享”。")
                companyStep(3, "共享来源选择有线/USB 网卡，共享到“Wi-Fi”，并设置热点名称和密码。")
                companyStep(4, "iPhone 连接 Mac 热点；PhoneBridge 中关闭“附近设备投屏”，再启动 iPhone 接收器。")
            }

            HStack {
                Button {
                    openInternetSharingSettings()
                } label: {
                    Label("打开互联网共享设置", systemImage: "gearshape")
                }
                .buttonStyle(.borderedProminent)

                Text("PhoneBridge 不会自动修改系统网络设置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Label("Android USB 不受影响；Android 无线 ADB 需要让手机也连接这个 Mac 热点，切换网络后重新连接一次即可。", systemImage: "checkmark.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label("如果公司 MDM 禁止“互联网共享”，请改用随身路由器或另一台手机热点。", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func companyStep(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 21, height: 21)
                .background(Color.blue, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openInternetSharingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

private enum FirstLaunchGuidePage: String, CaseIterable, Identifiable {
    case transfer
    case connection
    case companyNetwork
    case mirroring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transfer: return "文件互传"
        case .connection: return "连接手机"
        case .companyNetwork: return "公司网络投屏"
        case .mirroring: return "投屏与截录"
        }
    }

    var symbol: String {
        switch self {
        case .transfer: return "arrow.left.arrow.right"
        case .connection: return "cable.connector"
        case .companyNetwork: return "wifi.router"
        case .mirroring: return "airplayvideo"
        }
    }

    var summary: String {
        switch self {
        case .transfer: return "Mac 在左侧，手机在右侧；浏览、勾选或拖拽即可完成图片和视频传输。"
        case .connection: return "有线连接最稳定，无线入口集中在主界面底部的“无线连接”和“无线传输”。"
        case .companyNetwork: return "公司 Wi-Fi 经常隔离终端，推荐由 Mac 创建独立热点完成无线投屏。"
        case .mirroring: return "Android 使用独立 scrcpy 窗口；iPhone 可选择内嵌或独立窗口，并支持截屏和录屏。"
        }
    }

    var points: [String] {
        switch self {
        case .transfer:
            return [
                "把手机图片或视频拖到 Mac 面板，或多选后点击“传输到 Mac”。",
                "把 Mac 文件拖到 Android 面板可直接写入当前目录；拖到 iPhone 面板会生成一次性下载页。",
                "点击名称、大小或日期可刷新并排序；传到 Mac 的文件会以传输完成时间作为修改日期。"
            ]
        case .connection:
            return [
                "Android 首次连接要开启 USB 调试并在手机上授权；无线调试支持二维码配对。",
                "iPhone 首次连接数据线时保持解锁，并在手机上选择“信任”。",
                "没有数据线时仍可从“无线连接”直接启动 iPhone AirPlay 接收器。"
            ]
        case .companyNetwork:
            return []
        case .mirroring:
            return [
                "Android 投屏固定使用独立窗口，可保留低延迟控制和剪贴板能力。",
                "iPhone 可以在内嵌侧栏和独立窗口之间切换，并选择清晰度档位。",
                "投屏工具栏可保存 PNG 截屏或 MP4 录像，默认记住上次保存目录。"
            ]
        }
    }

    var tip: String? {
        switch self {
        case .transfer: return "连接多台手机时，每台设备会按连接顺序显示为独立面板。"
        case .connection: return "USB 连接不会因为启用公司网络模式而受到影响。"
        case .companyNetwork: return nil
        case .mirroring: return "截屏和录屏 Android 窗口前，需要允许 PhoneBridge 使用“屏幕与系统录音”。"
        }
    }
}
