import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct WirelessTransferView: View {
    @ObservedObject var service: WirelessTransferService
    let onStop: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("手机无线传输")
                        .font(.title2.bold())
                    Text(service.sharedFilename == nil ? "手机可上传照片、视频或文件到当前 Mac 目录" : "扫描二维码，把文件或 Charles CA 下载到手机")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") {
                    onStop()
                    dismiss()
                }
            }

            Divider()

            switch service.state {
            case .idle, .starting:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("正在启动局域网传输页面…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("无线传输无法启动")
                        .font(.headline)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 440)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .ready:
                readyContent
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 590)
        .onDisappear(perform: onStop)
    }

    private var readyContent: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(spacing: 12) {
                if let url = service.primaryURL {
                    QRCodeView(text: url.absoluteString)
                        .frame(width: 260, height: 260)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)

                    Text("手机扫码打开")
                        .font(.headline)
                    Text(url.absoluteString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)

                    HStack {
                        Button(copied ? "已复制" : "复制地址") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            copied = true
                        }
                        Button("在 Mac 中测试") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            .frame(width: 300)

            VStack(alignment: .leading, spacing: 14) {
                if let filename = service.sharedFilename {
                    Label(
                        service.sharedFilenames.count > 1
                            ? "已共享 \(service.sharedFilenames.count) 个文件（含 \(filename)）"
                            : "已共享：\(filename)",
                        systemImage: "checkmark.circle.fill"
                    )
                        .foregroundStyle(.green)
                    Text("iPhone 扫码后逐个下载，可从系统分享菜单选择“存储到文件”和具体文件夹；证书仍需手动安装并开启完全信任。")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Charles CA 安装步骤") {
                    VStack(alignment: .leading, spacing: 9) {
                        Label("保持手机和 Mac 在同一局域网", systemImage: "1.circle")
                        Label("扫码下载 .cer / .crt / .mobileconfig", systemImage: "2.circle")
                        Label("设置 → 通用 → VPN 与设备管理 → 安装", systemImage: "3.circle")
                        Label("设置 → 通用 → 关于本机 → 证书信任设置 → 完全信任", systemImage: "4.circle")
                        Link("已连接 Charles 代理？也可打开 chls.pro/ssl", destination: URL(string: "http://chls.pro/ssl")!)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                if !service.receivedFiles.isEmpty {
                    GroupBox("本次收到") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(service.receivedFiles.prefix(6), id: \.self) { filename in
                                Label(filename, systemImage: "arrow.down.doc")
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }

                Spacer()
                Text("该链接带有一次性随机令牌；关闭窗口后服务停止，旧链接立即失效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(from: text) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
        }
    }

    private static func image(from text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
