import Foundation
import SwiftUI
import UniformTypeIdentifiers

private enum FileSortField {
    case name
    case size
    case date
}

private struct FileSortOption {
    var field: FileSortField
    var ascending: Bool
}

private struct PathBreadcrumb: Identifiable {
    let path: String
    let label: String
    var id: String { path }
}

private enum MediaKindFilter: String, CaseIterable, Identifiable {
    case all
    case images
    case videos

    var id: Self { self }

    var label: String {
        switch self {
        case .all: return "全部"
        case .images: return "照片"
        case .videos: return "视频"
        }
    }
}

private struct PendingTransferRequest {
    let entries: [RemoteEntry]
    let destination: URL
    let conflictingFilenames: [String]
    let clearsSelection: Bool
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedRemoteIDsByDevice: [String: Set<String>] = [:]
    @State private var isMacDropTargeted = false
    @State private var macDropHighlightGeneration = 0
    @State private var localSort = FileSortOption(field: .name, ascending: true)
    @State private var remoteSortByDevice: [String: FileSortOption] = [:]
    @State private var localSearchText = ""
    @State private var remoteSearchByDevice: [String: String] = [:]
    @State private var remoteKindFilterByDevice: [String: MediaKindFilter] = [:]
    @State private var isMirrorSidebarVisible = false
    @State private var isMirrorFocusMode = false
    @State private var pendingTransferRequest: PendingTransferRequest?
    @State private var isShowingConflictDialog = false
    @State private var isWirelessTransferPresented = false
    @State private var isWirelessConnectionPresented = false
    @State private var textTransferDevice: PhoneDevice?
    @State private var draggingDevicePanelID: String?
    @State private var phoneDropTargetedDeviceIDs = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            if isMirrorFocusMode {
                mirrorSidebar
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    macPanel
                        .frame(minWidth: 420)
                    if model.devices.isEmpty {
                        emptyPhonePanel
                            .frame(minWidth: 360, idealWidth: 440)
                    } else {
                        ForEach(model.devices) { device in
                            phonePanel(for: device)
                                .frame(minWidth: 360, idealWidth: 460)
                        }
                    }
                    if isMirrorSidebarVisible {
                        mirrorSidebar
                            .frame(minWidth: 300, idealWidth: 360, maxWidth: 520)
                    }
                }
                Divider()
                transferBar
            }
            Divider()
            statusBar
        }
        .frame(
            minWidth: isMirrorFocusMode ? 720 : (isMirrorSidebarVisible ? 1_280 : 980),
            minHeight: 620
        )
        .alert("PhoneBridge", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            conflictDialogTitle,
            isPresented: $isShowingConflictDialog,
            titleVisibility: .visible
        ) {
            Button("跳过同名文件") {
                performPendingTransfer(conflictPolicy: .skip)
            }
            Button("自动重命名（推荐）") {
                performPendingTransfer(conflictPolicy: .rename)
            }
            Button("覆盖 Mac 上的文件", role: .destructive) {
                performPendingTransfer(conflictPolicy: .overwrite)
            }
            Button("取消", role: .cancel) {
                pendingTransferRequest = nil
            }
        } message: {
            Text(conflictDialogMessage)
        }
        .onChange(of: model.selectedDeviceID) { _ in
            isMirrorFocusMode = false
            model.stopCurrentEmbeddedMirroring()
        }
        .onDisappear {
            model.stopCurrentEmbeddedMirroring()
        }
        .sheet(isPresented: $isWirelessTransferPresented) {
            WirelessTransferView(
                service: model.wirelessTransferService,
                onStop: model.stopWirelessTransferPortal
            )
        }
        .sheet(isPresented: $isWirelessConnectionPresented) {
            WirelessConnectionView(model: model) {
                isMirrorFocusMode = false
                isMirrorSidebarVisible = true
            }
        }
        .sheet(item: $textTransferDevice) { device in
            TextTransferView(
                model: model,
                service: model.wirelessTransferService,
                device: device
            )
        }
    }

    private var macPanel: some View {
        let entries = visibleLocalEntries
        return MacDropReceiver(
            typeIdentifier: RemoteDragCodec.typeIdentifier,
            onTargeted: updateMacDropTarget,
            onData: { data in receiveDrop(data, destination: model.localPath) }
        ) {
            VStack(spacing: 0) {
                panelTitle(symbol: "desktopcomputer", title: "Mac") {
                    Button(action: model.chooseLocalDirectory) {
                        Label("选择文件夹", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.borderless)
                }

                pathBar(
                    path: model.localPath.path,
                    canGoBack: model.localPath.path != "/",
                    backAction: model.localParent,
                    navigateAction: { model.openLocalDirectory(URL(fileURLWithPath: $0, isDirectory: true)) },
                    refreshAction: model.refreshLocal,
                    searchText: $localSearchText,
                    searchPlaceholder: "搜索 Mac"
                )

                columnHeader(sort: $localSort)
                GeometryReader { geometry in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if entries.isEmpty {
                                EmptyListMessage(
                                    title: localSearchText.isEmpty ? "当前文件夹为空" : "没有匹配的文件",
                                    symbol: localSearchText.isEmpty ? "folder" : "magnifyingglass"
                                )
                            }
                            ForEach(entries) { entry in
                                LocalEntryRow(entry: entry)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 2)
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        TapGesture(count: 2)
                                            .exclusively(before: TapGesture(count: 1))
                                            .onEnded { result in
                                                switch result {
                                                case .first:
                                                    model.openLocalEntry(entry)
                                                case .second:
                                                    if !entry.isDirectory { model.openLocalEntry(entry) }
                                                }
                                            }
                                    )
                                    .onDrag {
                                        LocalFileDragCodec.provider(for: entry.url)
                                    }
                                    .contextMenu {
                                        Button {
                                            model.openLocalEntry(entry)
                                        } label: {
                                            Label(entry.isDirectory ? "打开文件夹" : "打开", systemImage: "arrow.up.forward.app")
                                        }
                                        Divider()
                                        Button {
                                            model.revealInFinder(entry)
                                        } label: {
                                            Label("在 Finder 中显示", systemImage: "magnifyingglass")
                                        }
                                        Button {
                                            model.copyLocalEntry(entry)
                                        } label: {
                                            Label("拷贝", systemImage: "doc.on.doc")
                                        }
                                        Divider()
                                        Button(role: .destructive) {
                                            model.moveLocalEntryToTrash(entry)
                                        } label: {
                                            Label("移到废纸篓", systemImage: "trash")
                                        }
                                    }
                                Divider()
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .top)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
                .contextMenu { localBackgroundContextMenu }
                .overlay {
                    if isMacDropTargeted {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                            .background(Color.accentColor.opacity(0.08))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }

                HStack {
                    Image(systemName: "arrow.left")
                    Text("单击打开；右键拷贝/新建/粘贴；整个左侧面板可接收拖入")
                    Spacer()
                    Text(resultCountText(visible: entries.count, total: model.localEntries.count))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .contextMenu { localBackgroundContextMenu }
            }
        }
    }

    private var emptyPhonePanel: some View {
        VStack(spacing: 0) {
            panelTitle(symbol: "iphone.slash", title: "手机") {
                Button {
                    Task { await model.refreshDevices() }
                } label: {
                    Label("刷新设备", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            EmptyStateView(
                title: "等待手机连接",
                symbol: "cable.connector",
                detail: "Android 请开启 USB/无线调试；iPhone 请解锁并信任此 Mac。"
            )
        }
    }

    private func phonePanel(for device: PhoneDevice) -> some View {
        let deviceID = device.id
        let allEntries = model.remoteEntries(for: deviceID)
        let entries = visibleRemoteEntries(for: deviceID)
        let selectedIDs = selectedRemoteIDsByDevice[deviceID] ?? []
        let selectedFiles = allEntries.filter { selectedIDs.contains($0.id) && !$0.isDirectory }
        let visibleFileIDs = Set(entries.filter { !$0.isDirectory }.map(\.id))
        let allVisibleFilesSelected = !visibleFileIDs.isEmpty && visibleFileIDs.isSubset(of: selectedIDs)
        return VStack(spacing: 0) {
            panelTitle(symbol: device.platform.symbolName, title: device.name) {
                if model.isRefreshing(deviceID: deviceID) {
                    ProgressView().controlSize(.small)
                }

                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                    .onDrag {
                        draggingDevicePanelID = deviceID
                        return NSItemProvider(object: deviceID as NSString)
                    }
                    .help("拖动调整设备面板顺序")

                Button {
                    model.selectDevice(deviceID)
                    isMirrorSidebarVisible = true
                } label: {
                    Label(
                        model.selectedDeviceID == deviceID && isMirrorSidebarVisible ? "正在投屏区" : "投屏",
                        systemImage: "rectangle.on.rectangle"
                    )
                }
                .buttonStyle(.borderless)

                Button {
                    if model.chooseAndSendFiles(to: deviceID) {
                        isWirelessTransferPresented = true
                    }
                } label: {
                    Label(
                        "传输到手机",
                        systemImage: "arrow.right"
                    )
                }
                .buttonStyle(.borderless)

                Button {
                    textTransferDevice = device
                } label: {
                    Label("文本", systemImage: "text.bubble")
                }
                .buttonStyle(.borderless)
                .help("发送网站链接或文本到手机")

                Button {
                    Task { await model.refreshRemote(deviceID: deviceID) }
                } label: {
                    Label("刷新文件", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 7, height: 7)
                Text(device.platform.displayName)
                    .font(.caption.weight(.medium))
                Spacer()
                Text(device.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            pathBar(
                path: model.remotePath(for: deviceID),
                canGoBack: device.platform == .android && model.remotePath(for: deviceID) != "/",
                backAction: { model.remoteParent(deviceID: deviceID) },
                navigateAction: { model.navigateRemote(to: $0, deviceID: deviceID) },
                refreshAction: { Task { await model.refreshRemote(deviceID: deviceID) } },
                searchText: remoteSearchBinding(for: deviceID),
                searchPlaceholder: "搜索 \(device.name)"
            )

            HStack(spacing: 10) {
                Picker("类型", selection: remoteFilterBinding(for: deviceID)) {
                    ForEach(MediaKindFilter.allCases) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)

                Text("已选 \(selectedFiles.count) 个")
                    .font(.caption)
                    .foregroundStyle(selectedFiles.isEmpty ? .secondary : .primary)
                Spacer()
                Button(allVisibleFilesSelected ? "取消当前选择" : "全选当前结果") {
                    if allVisibleFilesSelected {
                        selectedRemoteIDsByDevice[deviceID, default: []].subtract(visibleFileIDs)
                    } else {
                        selectedRemoteIDsByDevice[deviceID, default: []].formUnion(visibleFileIDs)
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(visibleFileIDs.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            columnHeader(sort: remoteSortBinding(for: deviceID))
            if entries.isEmpty {
                EmptyStateView(
                    title: hasActiveRemoteFilter(deviceID: deviceID) ? "没有匹配的文件" : "没有可显示的媒体",
                    symbol: hasActiveRemoteFilter(deviceID: deviceID) ? "line.3.horizontal.decrease.circle" : "photo.on.rectangle.angled",
                    detail: hasActiveRemoteFilter(deviceID: deviceID)
                        ? "请切换照片/视频类型、缩短关键词或清空搜索条件。"
                        : "刷新后仍为空时，请确认手机已解锁且当前目录包含图片或视频。"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            HStack(spacing: 8) {
                                if entry.isDirectory {
                                    Color.clear.frame(width: 18, height: 18)
                                } else {
                                    Button {
                                        toggleRemoteSelection(entry.id, deviceID: deviceID)
                                    } label: {
                                        Image(systemName: selectedIDs.contains(entry.id)
                                            ? "checkmark.square.fill"
                                            : "square")
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundStyle(selectedIDs.contains(entry.id) ? Color.accentColor : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(selectedIDs.contains(entry.id)
                                        ? "取消勾选 \(entry.name)"
                                        : "勾选 \(entry.name)")
                                }

                                RemoteEntryRow(entry: entry)
                            }
                            .padding(.horizontal, 12)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) {
                                model.openRemoteDirectory(entry, deviceID: deviceID)
                            }
                            .onDrag {
                                let dragged = selectedIDs.contains(entry.id)
                                    ? entries.filter { selectedIDs.contains($0.id) && !$0.isDirectory }
                                    : [entry].filter { !$0.isDirectory }
                                model.statusMessage = "正在拖动：\(dragged.count) 个媒体文件"
                                return RemoteDragCodec.provider(for: dragged)
                            }
                            Divider()
                                .padding(.leading, 42)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }

            VStack(spacing: 5) {
                HStack {
                    Text("手机文件可拖到 Mac；Mac 文件也可拖入当前手机目录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        requestTransfer(selectedFiles, to: model.localPath, clearsSelection: true)
                    } label: {
                        Label("传输到 Mac（\(selectedFiles.count)）", systemImage: "arrow.left")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(selectedFiles.isEmpty)
                }

                HStack {
                    if model.thumbnailLoadedCount(for: deviceID) > 0
                        || model.thumbnailFailureCount(for: deviceID) > 0 {
                        Text("缩略图 \(model.thumbnailLoadedCount(for: deviceID)) 个")
                        if model.thumbnailFailureCount(for: deviceID) > 0 {
                            Text("\(model.thumbnailFailureCount(for: deviceID)) 个失败")
                                .foregroundStyle(.red)
                                .help(model.firstThumbnailError(for: deviceID) ?? "缩略图加载失败")
                        }
                    }
                    Spacer()
                    Text(resultCountText(
                        visible: entries.filter { !$0.isDirectory }.count,
                        total: allEntries.filter { !$0.isDirectory }.count
                    ))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
        }
        .overlay {
            if phoneDropTargetedDeviceIDs.contains(deviceID) {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .background(Color.accentColor.opacity(0.08))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [UTType.text, UTType.fileURL],
            delegate: PhonePanelDropDelegate(
                targetID: deviceID,
                draggingID: $draggingDevicePanelID,
                move: model.moveDevicePanel,
                setFileTargeted: { targeted in
                    if targeted {
                        phoneDropTargetedDeviceIDs.insert(deviceID)
                    } else {
                        phoneDropTargetedDeviceIDs.remove(deviceID)
                    }
                },
                receiveFiles: { providers in
                    receiveLocalFileDrop(providers, deviceID: deviceID)
                }
            )
        )
    }

    private var mirrorSidebar: some View {
        VStack(spacing: 0) {
            panelTitle(symbol: "rectangle.on.rectangle", title: "手机投屏") {
                Button {
                    isMirrorFocusMode.toggle()
                } label: {
                    Image(systemName: isMirrorFocusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help(isMirrorFocusMode ? "退出放大投屏" : "放大投屏")

                Button {
                    isMirrorFocusMode = false
                    isMirrorSidebarVisible = false
                    model.stopCurrentEmbeddedMirroring()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("关闭投屏侧栏")
            }

            switch model.activeMirrorPlatform ?? model.selectedDevice?.platform {
            case .ios:
                Picker("显示方式", selection: Binding(
                    get: { model.iPhoneMirrorMode },
                    set: { model.setIPhoneMirrorMode($0) }
                )) {
                    ForEach(IPhoneMirrorMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 10)

                if model.iPhoneMirrorMode == .embedded {
                    EmbeddedIPhoneMirrorView(service: model.embeddedIPhoneMirrorService)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(model.embeddedIPhoneMirrorService.state.isRunning ? 2 : 10)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("iPhone 独立投屏窗口")
                            .font(.headline)
                        Text("启动后，PhoneBridge 会在原生独立窗口中显示 iPhone 画面；关闭侧栏不会遮挡文件面板。")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 360)
                        Button {
                            model.showIPhoneMirrorWindow()
                        } label: {
                            Label("显示独立窗口", systemImage: "macwindow")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.mirroringService.iPhoneAirPlayProcessID == nil)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
                }

                HStack(spacing: 8) {
                    Picker("画质", selection: Binding(
                        get: { model.iPhoneMirrorQuality },
                        set: { model.setIPhoneMirrorQuality($0) }
                    )) {
                        ForEach(IPhoneMirrorQuality.allCases) { quality in
                            Text(quality.label).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 118)

                    if model.iPhoneMirrorMode == .embedded,
                       let size = model.embeddedIPhoneMirrorService.framePixelSize {
                        Text("\(Int(size.width))×\(Int(size.height))")
                    }
                    if model.iPhoneMirrorMode == .embedded,
                       model.embeddedIPhoneMirrorService.framesPerSecond > 0 {
                        Text(String(format: "%.1f fps", model.embeddedIPhoneMirrorService.framesPerSecond))
                    }
                    Spacer()
                    Button("名称与无线设置") {
                        isWirelessConnectionPresented = true
                    }
                    .buttonStyle(.borderless)
                    .help("当前接收名称：\(model.iPhoneAirPlayName)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                HStack(spacing: 8) {
                    Toggle("附近模式", isOn: Binding(
                        get: { model.iPhonePeerToPeerEnabled },
                        set: { model.setIPhonePeerToPeerEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    if model.iPhonePeerToPeerEnabled {
                        Text("PIN \(model.iPhonePeerToPeerPIN)")
                            .font(.caption.monospaced().bold())
                            .textSelection(.enabled)
                        Button("换一个", action: model.regenerateIPhonePeerToPeerPIN)
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                HStack(spacing: 8) {
                    Button {
                        model.startIPhoneMirroring(allowWithoutConnectedDevice: true)
                    } label: {
                        Label(
                            model.mirroringService.iPhoneAirPlayProcessID != nil ? "重新启动" : "启动 AirPlay",
                            systemImage: "airplayvideo"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Button("停止") {
                        model.stopIPhoneMirroring()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.mirroringService.iPhoneAirPlayProcessID == nil)

                    Button("刷新画面") {
                        model.restartIPhoneMirroring()
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.mirroringService.iPhoneAirPlayProcessID == nil)
                }
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

                if model.iPhoneMirrorMode == .separateWindow || !model.embeddedIPhoneMirrorService.state.isRunning {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(
                            model.iPhonePeerToPeerEnabled
                                ? "保持 Mac 与 iPhone 的 Wi-Fi/蓝牙开启"
                                : "Mac 与 iPhone 连接同一局域网",
                            systemImage: "1.circle"
                        )
                        Label("打开 iPhone 控制中心 → 屏幕镜像", systemImage: "2.circle")
                        Label(
                            model.iPhonePeerToPeerEnabled
                                ? "选择“\(model.iPhoneAirPlayName)”并输入 PIN"
                                : "选择“\(model.iPhoneAirPlayName)”，无需登录 Apple ID",
                            systemImage: "3.circle"
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }

            case .android:
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("scrcpy 独立窗口")
                        .font(.headline)
                    Text("Android 投屏固定使用独立窗口，保留最低延迟、键鼠控制、剪贴板和拖放能力；USB 调试与无线 ADB 均可使用。")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 360)
                    HStack {
                        Button {
                            model.startUSBScreenMirroring()
                        } label: {
                            Label("打开独立窗口", systemImage: "macwindow")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("停止") {
                            model.stopSelectedAndroidMirroring()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            case nil:
                EmptyStateView(
                    title: "等待手机连接",
                    symbol: "cable.connector",
                    detail: "连接并解锁手机后，可以在这里启动投屏。"
                )
            }

            if model.activeMirrorPlatform != nil
                || model.mirrorCaptureService.isRecording
                || model.mirrorCaptureService.isFinishing
                || model.mirrorCaptureService.hasPendingRecording {
                Divider()
                MirrorCaptureToolbar(
                    service: model.mirrorCaptureService,
                    onScreenshot: model.captureMirrorScreenshot,
                    onStartRecording: model.startMirrorRecording,
                    onStopRecording: model.stopMirrorRecording,
                    onSavePendingRecording: model.savePendingMirrorRecording
                )
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var transferBar: some View {
        VStack(spacing: 6) {
            if model.transfers.isEmpty {
                HStack {
                    Image(systemName: "arrow.left.arrow.right")
                    Text("传输队列为空")
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .font(.caption)
            } else {
                ForEach(model.transfers.prefix(4)) { job in
                    HStack(spacing: 10) {
                        transferIcon(job.state)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.sourceName)
                                .lineLimit(1)
                            Text(job.destination.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(job.destination.path)
                        }
                        .frame(width: 260, alignment: .leading)
                        ProgressView(value: job.progress)
                        Text(transferDetailText(job))
                            .font(.caption)
                            .foregroundStyle(transferColor(job.state))
                            .lineLimit(1)
                            .frame(width: 190, alignment: .trailing)
                            .help(transferHelpText(job))
                        if case .failed = job.state {
                            Button("重试") {
                                model.retryTransfer(job.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                HStack {
                    Text("共 \(model.transfers.count) 个任务")
                    Spacer()
                    Button("清除已完成", action: model.clearFinishedTransfers)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 38)
    }

    private var statusBar: some View {
        HStack {
            Circle()
                .fill(model.devices.isEmpty ? Color.secondary : Color.green)
                .frame(width: 7, height: 7)
            Text(model.statusMessage)
                .lineLimit(1)
            Spacer()
            Button {
                isWirelessConnectionPresented = true
            } label: {
                Label("无线连接", systemImage: "wifi")
            }
            .buttonStyle(.borderless)

            Button {
                model.startWirelessTransferPortal()
                isWirelessTransferPresented = true
            } label: {
                Label("无线传输", systemImage: "qrcode")
            }
            .buttonStyle(.borderless)

            Text("PhoneBridge · \(model.devices.count) 台设备")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func panelTitle<Trailing: View>(symbol: String, title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.headline)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func pathBar(
        path: String,
        canGoBack: Bool,
        backAction: @escaping () -> Void,
        navigateAction: @escaping (String) -> Void,
        refreshAction: @escaping () -> Void,
        searchText: Binding<String>,
        searchPlaceholder: String
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: backAction) { Image(systemName: "chevron.left") }
                .disabled(!canGoBack)
                .buttonStyle(.borderless)
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Array(breadcrumbs(for: path).enumerated()), id: \.element.id) { index, segment in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        Button(segment.label) {
                            navigateAction(segment.path)
                        }
                        .buttonStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(index == breadcrumbs(for: path).count - 1 ? Color.primary : Color.accentColor)
                        .help("跳转到 \(segment.path)")
                    }
                }
                .frame(minHeight: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchPlaceholder, text: searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !searchText.wrappedValue.isEmpty {
                    Button {
                        searchText.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            }
            .padding(.horizontal, 7)
            .frame(width: 150, height: 24)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

            Button(action: refreshAction) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func breadcrumbs(for path: String) -> [PathBreadcrumb] {
        guard path.hasPrefix("/") else {
            return [PathBreadcrumb(path: path, label: path)]
        }
        let components = path.split(separator: "/").map(String.init)
        var result = [PathBreadcrumb(path: "/", label: "/")]
        var current = ""
        for component in components {
            current += "/" + component
            result.append(PathBreadcrumb(path: current, label: component))
        }
        return result
    }

    private func columnHeader(sort: Binding<FileSortOption>) -> some View {
        HStack(spacing: 8) {
            sortHeaderButton("名称", field: .name, sort: sort, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeaderButton("大小", field: .size, sort: sort, alignment: .trailing)
                .frame(width: 84, alignment: .trailing)
            sortHeaderButton("日期", field: .date, sort: sort, alignment: .trailing)
                .frame(width: 130, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sortHeaderButton(
        _ title: String,
        field: FileSortField,
        sort: Binding<FileSortOption>,
        alignment: Alignment
    ) -> some View {
        Button {
            if sort.wrappedValue.field == field {
                sort.wrappedValue.ascending.toggle()
            } else {
                sort.wrappedValue = FileSortOption(field: field, ascending: field == .name)
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if sort.wrappedValue.field == field {
                    Image(systemName: sort.wrappedValue.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按\(title)排序；再次点击切换升降序")
    }

    private var visibleLocalEntries: [LocalEntry] {
        let query = localSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty
            ? model.localEntries
            : model.localEntries.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch localSort.field {
            case .name:
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                return localSort.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            case .size:
                if lhs.size != rhs.size { return localSort.ascending ? lhs.size < rhs.size : lhs.size > rhs.size }
            case .date:
                let leftDate = lhs.modifiedAt ?? .distantPast
                let rightDate = rhs.modifiedAt ?? .distantPast
                if leftDate != rightDate { return localSort.ascending ? leftDate < rightDate : leftDate > rightDate }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func remoteSortBinding(for deviceID: String) -> Binding<FileSortOption> {
        Binding(
            get: { remoteSortByDevice[deviceID] ?? FileSortOption(field: .date, ascending: false) },
            set: { remoteSortByDevice[deviceID] = $0 }
        )
    }

    private func remoteSearchBinding(for deviceID: String) -> Binding<String> {
        Binding(
            get: { remoteSearchByDevice[deviceID] ?? "" },
            set: { remoteSearchByDevice[deviceID] = $0 }
        )
    }

    private func remoteFilterBinding(for deviceID: String) -> Binding<MediaKindFilter> {
        Binding(
            get: { effectiveMediaFilter(for: deviceID) },
            set: { filter in
                remoteKindFilterByDevice[deviceID] = filter
                guard model.devices.first(where: { $0.id == deviceID })?.platform == .android else { return }
                switch filter {
                case .all: model.setAndroidMediaScope(.folder, deviceID: deviceID)
                case .images: model.setAndroidMediaScope(.images, deviceID: deviceID)
                case .videos: model.setAndroidMediaScope(.videos, deviceID: deviceID)
                }
            }
        )
    }

    private func effectiveMediaFilter(for deviceID: String) -> MediaKindFilter {
        if model.devices.first(where: { $0.id == deviceID })?.platform == .android {
            switch model.androidMediaScope(for: deviceID) {
            case .folder: return .all
            case .images: return .images
            case .videos: return .videos
            }
        }
        return remoteKindFilterByDevice[deviceID] ?? .all
    }

    private func visibleRemoteEntries(for deviceID: String) -> [RemoteEntry] {
        let query = (remoteSearchByDevice[deviceID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let kindFilter = effectiveMediaFilter(for: deviceID)
        let sort = remoteSortByDevice[deviceID] ?? FileSortOption(field: .date, ascending: false)
        let kindFiltered = model.remoteEntries(for: deviceID).filter { entry in
            if entry.isDirectory { return true }
            switch kindFilter {
            case .all: return true
            case .images: return entry.kind == .image
            case .videos: return entry.kind == .video
            }
        }
        let filtered = query.isEmpty
            ? kindFiltered
            : kindFiltered.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch sort.field {
            case .name:
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                return sort.ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            case .size:
                if lhs.size != rhs.size { return sort.ascending ? lhs.size < rhs.size : lhs.size > rhs.size }
            case .date:
                let leftDate = lhs.modifiedAt ?? .distantPast
                let rightDate = rhs.modifiedAt ?? .distantPast
                if leftDate != rightDate { return sort.ascending ? leftDate < rightDate : leftDate > rightDate }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func hasActiveRemoteFilter(deviceID: String) -> Bool {
        effectiveMediaFilter(for: deviceID) != .all
            || !(remoteSearchByDevice[deviceID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resultCountText(visible: Int, total: Int) -> String {
        visible == total ? "\(total) 个" : "显示 \(visible)/\(total) 个"
    }

    private func updateMacDropTarget(_ targeted: Bool) {
        macDropHighlightGeneration += 1
        let generation = macDropHighlightGeneration
        if targeted {
            isMacDropTargeted = true
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard generation == macDropHighlightGeneration else { return }
            isMacDropTargeted = false
        }
    }

    @ViewBuilder
    private var localBackgroundContextMenu: some View {
        Button {
            model.promptAndCreateLocalFolder()
        } label: {
            Label("新建文件夹", systemImage: "folder.badge.plus")
        }
        Button {
            model.promptAndCreateLocalFile()
        } label: {
            Label("新建文件", systemImage: "doc.badge.plus")
        }
        Divider()
        Button {
            model.pasteLocalItems()
        } label: {
            Label("粘贴项目", systemImage: "doc.on.clipboard")
        }
        .disabled(!model.canPasteLocalItems)
    }

    private var conflictDialogTitle: String {
        guard let request = pendingTransferRequest else { return "发现同名文件" }
        return "发现 \(request.conflictingFilenames.count) 个同名文件"
    }

    private var conflictDialogMessage: String {
        guard let request = pendingTransferRequest else { return "请选择处理方式。" }
        let preview = request.conflictingFilenames.prefix(3).joined(separator: "、")
        let more = request.conflictingFilenames.count > 3 ? " 等" : ""
        return "Mac 中已经存在：\(preview)\(more)。请选择跳过、保留两份，或覆盖 Mac 上的原文件。"
    }

    private func toggleRemoteSelection(_ id: String, deviceID: String) {
        if selectedRemoteIDsByDevice[deviceID, default: []].contains(id) {
            selectedRemoteIDsByDevice[deviceID, default: []].remove(id)
        } else {
            selectedRemoteIDsByDevice[deviceID, default: []].insert(id)
        }
    }

    private func removeRemoteSelections(_ ids: Set<String>) {
        for deviceID in selectedRemoteIDsByDevice.keys {
            selectedRemoteIDsByDevice[deviceID]?.subtract(ids)
        }
    }

    private func requestTransfer(
        _ entries: [RemoteEntry],
        to destination: URL,
        clearsSelection: Bool = false
    ) {
        let files = entries.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }
        let conflicts = model.conflictingFilenames(files, in: destination)
        guard !conflicts.isEmpty else {
            model.transfer(files, to: destination, conflictPolicy: .rename)
            if clearsSelection {
                removeRemoteSelections(Set(files.map(\.id)))
            }
            return
        }

        pendingTransferRequest = PendingTransferRequest(
            entries: files,
            destination: destination,
            conflictingFilenames: conflicts,
            clearsSelection: clearsSelection
        )
        isShowingConflictDialog = true
    }

    private func performPendingTransfer(conflictPolicy: TransferConflictPolicy) {
        guard let request = pendingTransferRequest else { return }
        model.transfer(request.entries, to: request.destination, conflictPolicy: conflictPolicy)
        if request.clearsSelection {
            removeRemoteSelections(Set(request.entries.map(\.id)))
        }
        pendingTransferRequest = nil
    }

    private func receiveDrop(_ providers: [NSItemProvider], destination: URL) -> Bool {
        RemoteDragCodec.receive(providers) { result in
            Task { @MainActor in
                switch result {
                case .success(let entries): requestTransfer(entries, to: destination)
                case .failure(let error): model.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func receiveDrop(_ data: Data, destination: URL) -> Bool {
        guard let entries = RemoteDragCodec.entries(from: data) else {
            model.errorMessage = PhoneBridgeError.invalidDropData.localizedDescription
            return false
        }
        requestTransfer(entries, to: destination)
        return true
    }

    private func receiveLocalFileDrop(_ providers: [NSItemProvider], deviceID: String) -> Bool {
        LocalFileDragCodec.receive(providers) { urls in
            guard !urls.isEmpty else {
                model.errorMessage = "没有读取到可传输的 Mac 文件。"
                return
            }
            if model.sendLocalFiles(urls, to: deviceID) {
                isWirelessTransferPresented = true
            }
        }
    }

    private func transferDetailText(_ job: TransferJob) -> String {
        switch job.state {
        case .queued:
            return "等待中 · \(formattedBytes(job.totalBytes))"
        case .running:
            let percentage = Int((job.progress * 100).rounded())
            if let remaining = job.estimatedRemaining {
                return "\(percentage)% · 剩余 \(formattedDuration(remaining))"
            }
            return "\(percentage)% · 正在估算"
        case .completed:
            return "100% · 已完成"
        case .failed:
            return "失败 · 可重试"
        }
    }

    private func transferHelpText(_ job: TransferJob) -> String {
        if case .failed(let message) = job.state { return message }
        if let speed = job.bytesPerSecond {
            return "当前速度：\(formattedBytes(Int64(speed)))/秒"
        }
        return job.destination.path
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        if seconds < 60 { return "\(seconds) 秒" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分\(seconds % 60)秒" }
        return "\(minutes / 60)小时\(minutes % 60)分"
    }

    @ViewBuilder
    private func transferIcon(_ state: TransferState) -> some View {
        switch state {
        case .queued: Image(systemName: "clock")
        case .running: ProgressView().controlSize(.mini)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func transferColor(_ state: TransferState) -> Color {
        switch state {
        case .completed: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}

private struct MirrorCaptureToolbar: View {
    @ObservedObject var service: MirrorCaptureService
    let onScreenshot: () -> Void
    let onStartRecording: () -> Void
    let onStopRecording: () -> Void
    let onSavePendingRecording: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onScreenshot) {
                Label("截屏", systemImage: "camera")
            }
            .buttonStyle(.bordered)
            .disabled(service.isFinishing)

            if service.isRecording {
                Button(action: onStopRecording) {
                    Label("停止并命名保存", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                HStack(spacing: 5) {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                    Text(Self.durationText(service.recordingDuration))
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Button(action: onStartRecording) {
                    Label("开始录屏", systemImage: "record.circle")
                }
                .buttonStyle(.bordered)
                .disabled(service.isFinishing || service.hasPendingRecording)
            }

            if service.isFinishing {
                ProgressView()
                    .controlSize(.small)
                Text("正在生成视频…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if service.hasPendingRecording {
                Button(action: onSavePendingRecording) {
                    Label("保存录像", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct LocalEntryRow: View {
    let entry: LocalEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
                .frame(width: 20)
            Text(entry.name).lineLimit(1)
            Spacer()
            Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            Text(entry.modifiedAt?.formatted(date: .numeric, time: .shortened) ?? "—")
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 2)
    }
}

private struct RemoteEntryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: RemoteEntry
    @State private var thumbnail: NSImage?
    @State private var isLoadingThumbnail = false

    var body: some View {
        HStack(spacing: 8) {
            thumbnailView
            Text(entry.name).lineLimit(1)
            Spacer()
            Text(entry.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .trailing)
            Text(entry.modifiedAt?.formatted(date: .numeric, time: .shortened) ?? "—")
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .task(id: entry.id) {
            guard !entry.isDirectory, thumbnail == nil else { return }
            isLoadingThumbnail = true
            if let data = await model.thumbnailData(for: entry) {
                thumbnail = NSImage(data: data)
            }
            isLoadingThumbnail = false
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.10))

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isLoadingThumbnail {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: entry.kind.symbolName)
                    .foregroundStyle(entry.isDirectory ? .blue : entry.kind == .video ? .purple : .green)
            }

            if entry.kind == .video, thumbnail != nil {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.48))
                    .shadow(radius: 1)
            }
        }
        .frame(width: 64, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct EmptyListMessage: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 48)
        .allowsHitTesting(false)
    }
}

private struct EmptyStateView: View {
    let title: String
    let symbol: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct PhonePanelDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggingID: String?
    let move: (String, String) -> Void
    let setFileTargeted: (Bool) -> Void
    let receiveFiles: ([NSItemProvider]) -> Bool

    func dropEntered(info: DropInfo) {
        if info.hasItemsConforming(to: [UTType.fileURL]) {
            setFileTargeted(true)
            return
        }
        guard let sourceID = draggingID, sourceID != targetID else { return }
        move(sourceID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [UTType.fileURL]) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        setFileTargeted(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { setFileTargeted(false) }
        if info.hasItemsConforming(to: [UTType.fileURL]) {
            return receiveFiles(info.itemProviders(for: [UTType.fileURL]))
        }
        draggingID = nil
        return true
    }
}
