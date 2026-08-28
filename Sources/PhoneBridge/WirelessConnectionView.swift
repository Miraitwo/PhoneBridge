import SwiftUI

struct WirelessConnectionView: View {
    @ObservedObject var model: AppModel
    let onOpenMirrorSidebar: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pairingEndpoint = ""
    @State private var pairingCode = ""
    @State private var connectionEndpoint = ""
    @State private var iPhoneReceiverName = ""
    @State private var isWorking = false
    @State private var isManualAndroidPairingExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("无线连接")
                        .font(.title2.bold())
                    Text("连接后，文件面板会按连接顺序自动加入主界面")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("完成", action: dismiss.callAsFunction)
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("iPhone AirPlay 投屏（名称与启动）") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("无需先连接数据线。先在这里设置一个容易区分的名称，再直接启动接收器。")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            HStack {
                                TextField("接收名称，例如 PhoneBridge · 小王", text: $iPhoneReceiverName)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit(applyIPhoneReceiverName)
                                Button("保存名称", action: applyIPhoneReceiverName)
                                    .buttonStyle(.borderedProminent)
                            }
                            Text("iPhone 的“屏幕镜像”列表将显示：\(model.iPhoneAirPlayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Picker("显示方式", selection: Binding(
                                get: { model.iPhoneMirrorMode },
                                set: { model.setIPhoneMirrorMode($0) }
                            )) {
                                ForEach(IPhoneMirrorMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            Divider()

                            Toggle("没有共同 Wi-Fi 时，使用附近设备投屏（AWDL）", isOn: Binding(
                                get: { model.iPhonePeerToPeerEnabled },
                                set: { model.setIPhonePeerToPeerEnabled($0) }
                            ))
                            Text("此模式不依赖数据线或共同路由器，但 Mac 与 iPhone 的 Wi-Fi、蓝牙都必须开启。")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            if model.iPhonePeerToPeerEnabled {
                                HStack(spacing: 12) {
                                    Text("连接 PIN")
                                    Text(model.iPhonePeerToPeerPIN)
                                        .font(.system(.title2, design: .monospaced).bold())
                                        .textSelection(.enabled)
                                    Button("更换 PIN", action: model.regenerateIPhonePeerToPeerPIN)
                                        .buttonStyle(.bordered)
                                }
                            }

                            HStack {
                                Button {
                                    model.selectWirelessIPhoneMirrorTarget()
                                    let wasActive = model.isWirelessIPhoneMirroring
                                    let previousName = model.iPhoneAirPlayName
                                    applyIPhoneReceiverName()
                                    if !wasActive || previousName == model.iPhoneAirPlayName {
                                        model.startIPhoneMirroring(allowWithoutConnectedDevice: true)
                                    }
                                    onOpenMirrorSidebar()
                                    dismiss()
                                } label: {
                                    Label("启动 iPhone 接收器", systemImage: "airplayvideo")
                                }
                                .buttonStyle(.borderedProminent)

                                Button("停止") {
                                    model.selectWirelessIPhoneMirrorTarget()
                                    model.stopIPhoneMirroring()
                                }
                                .buttonStyle(.bordered)
                                .disabled(!model.isWirelessIPhoneMirroring)
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("Android 无线调试") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("扫码配对（推荐）")
                                .font(.headline)
                            Text("Android 11 及以上：在手机上打开“设置 → 开发者选项 → 无线调试 → 使用二维码配对设备”，扫描下方二维码后会自动配对并连接。")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            if let request = model.androidQRPairingRequest {
                                HStack(alignment: .top, spacing: 18) {
                                    QRCodeView(text: request.payload)
                                        .frame(width: 190, height: 190)
                                        .padding(10)
                                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.secondary.opacity(0.25))
                                        }

                                    VStack(alignment: .leading, spacing: 12) {
                                        Label(model.androidQRPairingStatus, systemImage: androidQRPairingStatusSymbol)
                                            .font(.callout)
                                            .foregroundStyle(model.isAndroidQRPairing ? Color.primary : Color.secondary)
                                            .fixedSize(horizontal: false, vertical: true)

                                        if model.isAndroidQRPairing {
                                            ProgressView()
                                                .controlSize(.small)
                                        }

                                        Text("二维码为一次性随机凭据，有效等待时间约 2 分钟。手机和 Mac 需要处于同一局域网。")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        HStack {
                                            Button(model.isAndroidQRPairing ? "重新生成二维码" : "生成新二维码") {
                                                model.startAndroidQRPairing()
                                            }
                                            .buttonStyle(.borderedProminent)

                                            if model.isAndroidQRPairing {
                                                Button("停止") {
                                                    model.cancelAndroidQRPairing(clearRequest: false)
                                                }
                                                .buttonStyle(.bordered)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                Button {
                                    model.startAndroidQRPairing()
                                } label: {
                                    Label("生成配对二维码", systemImage: "qrcode")
                                }
                                .buttonStyle(.borderedProminent)
                            }

                            Divider()

                            DisclosureGroup("手动配对与连接（备用）", isExpanded: $isManualAndroidPairingExpanded) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("配对端口和连接端口通常不同。扫码不可用时，可使用手机显示的 6 位配对码和地址。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                                        GridRow {
                                            Text("配对地址")
                                            TextField("例如 192.168.1.20:37123", text: $pairingEndpoint)
                                        }
                                        GridRow {
                                            Text("6 位配对码")
                                            TextField("例如 123456", text: $pairingCode)
                                        }
                                    }

                                    Button("配对") {
                                        run {
                                            await model.pairAndroidWirelessly(endpoint: pairingEndpoint, code: pairingCode)
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(isWorking)

                                    HStack {
                                        TextField("连接地址，例如 192.168.1.20:42817", text: $connectionEndpoint)
                                        Button("连接") {
                                            run { await model.connectAndroidWirelessly(endpoint: connectionEndpoint) }
                                        }
                                        .buttonStyle(.borderedProminent)
                                        Button("断开") {
                                            run { await model.disconnectAndroidWirelessly(endpoint: connectionEndpoint) }
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    .disabled(isWorking)
                                }
                            }
                        }
                        .padding(6)
                    }

                    GroupBox("无线文件传输") {
                        Text("手机和 Mac 在同一局域网或热点中时，可从主界面底部点击“无线传输”，用 Safari/浏览器上传照片、视频或下载 Mac 文件。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }

                    Text(model.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(22)
            }
        }
        .frame(minWidth: 700, minHeight: 680)
        .onAppear {
            iPhoneReceiverName = model.iPhoneAirPlayName
        }
        .onDisappear {
            model.cancelAndroidQRPairing()
        }
    }

    private func applyIPhoneReceiverName() {
        model.selectWirelessIPhoneMirrorTarget()
        iPhoneReceiverName = model.setIPhoneAirPlayName(iPhoneReceiverName)
    }

    private var androidQRPairingStatusSymbol: String {
        if model.isAndroidQRPairing { return "qrcode.viewfinder" }
        if model.androidQRPairingStatus.contains("成功") { return "checkmark.circle" }
        return "exclamationmark.triangle"
    }

    private func run(_ operation: @escaping () async -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await operation()
            isWorking = false
        }
    }
}
