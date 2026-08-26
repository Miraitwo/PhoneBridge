import AppKit
import SwiftUI

struct TextTransferView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: WirelessTransferService
    let device: PhoneDevice

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var didStart = false
    @State private var didAutoOpenAndroid = false
    @State private var copiedAddress = false
    @State private var deviceStatus = ""

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("发送文本到 \(device.name)")
                        .font(.title2.bold())
                    Text("网站链接、验证账号或多行文本均可发送")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }

            Divider()

            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("在 Mac 上输入")
                        .font(.headline)
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 260)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.primary.opacity(0.10))
                        }
                        .accessibilityLabel("发送文本内容")

                    HStack {
                        Button("粘贴 Mac 剪贴板") {
                            if let value = NSPasteboard.general.string(forType: .string) {
                                text = value
                            }
                        }
                        Button("清空") { text = "" }
                            .disabled(text.isEmpty)
                        Spacer()
                        Text("\(text.count) 个字符")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        if model.startTextTransfer(text, targetDeviceID: device.id) {
                            didStart = true
                            didAutoOpenAndroid = false
                            copiedAddress = false
                            deviceStatus = device.platform == .android
                                ? "正在准备并自动打开 Android 页面…"
                                : "正在生成一次性手机页面…"
                        }
                    } label: {
                        Label(didStart ? "更新手机页面" : "生成手机页面", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(minWidth: 390)

                GroupBox("在手机上接收") {
                    VStack(spacing: 12) {
                        portalContent
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(8)
                }
                .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
            }

            Text("文本只在 Mac 和手机之间传输，不会上传到云端；关闭窗口后链接立即失效。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 610)
        .onChange(of: service.state) { state in
            guard didStart, case .ready = state else { return }
            if device.platform == .android, !didAutoOpenAndroid {
                didAutoOpenAndroid = true
                Task {
                    if let openedURL = await model.openTextTransferPageOnAndroid(deviceID: device.id) {
                        deviceStatus = openedURL.host == "127.0.0.1"
                            ? "已通过 USB / ADB 在 Android 浏览器打开"
                            : "已在 Android 浏览器打开"
                    } else {
                        deviceStatus = "自动打开失败，请扫码或手动打开地址"
                    }
                }
            } else if device.platform == .ios {
                deviceStatus = "请使用 iPhone 扫码打开"
            }
        }
        .onDisappear(perform: model.stopWirelessTransferPortal)
    }

    @ViewBuilder
    private var portalContent: some View {
        switch service.state {
        case .idle:
            placeholder(
                symbol: "text.bubble",
                title: "等待生成",
                detail: "手机页面会提供复制、系统分享和打开链接功能。"
            )
        case .starting:
            ProgressView("正在启动本地页面…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            placeholder(symbol: "wifi.exclamationmark", title: "启动失败", detail: message)
        case .ready:
            if let url = service.primaryURL {
                QRCodeView(text: url.absoluteString)
                    .frame(width: 190, height: 190)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                Text(deviceStatus)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                Text(url.absoluteString)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                HStack {
                    Button(copiedAddress ? "已复制地址" : "复制地址") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        copiedAddress = true
                    }
                    if device.platform == .android {
                        Button("再次自动打开") {
                            Task {
                                _ = await model.openTextTransferPageOnAndroid(deviceID: device.id)
                            }
                        }
                    }
                }
                Text("手机页面中点击“复制文本”可写入剪贴板；点击“分享”可选择备忘录或其他 App。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func placeholder(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
