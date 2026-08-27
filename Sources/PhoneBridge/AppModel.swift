import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    private static let lastLocalDirectoryKey = "PhoneBridge.lastLocalDirectory"
    private static let iPhoneMirrorQualityKey = "PhoneBridge.iPhoneMirrorQuality"
    private static let iPhoneAirPlayNameKey = "PhoneBridge.iPhoneAirPlayName"
    private static let iPhonePeerToPeerKey = "PhoneBridge.iPhonePeerToPeer"
    private static let iPhonePeerToPeerPINKey = "PhoneBridge.iPhonePeerToPeerPIN"
    private static let iPhoneMirrorModeKey = "PhoneBridge.iPhoneMirrorMode"
    private static let lastMirrorCaptureDirectoryKey = "PhoneBridge.lastMirrorCaptureDirectory"

    private struct PendingTransfer {
        let jobID: UUID
        let entry: RemoteEntry
        let destination: URL
        let overwriteExisting: Bool
    }

    private struct PendingUpload {
        let jobID: UUID
        let source: URL
        let deviceID: String
        let remoteDirectory: String
    }

    @Published var devices: [PhoneDevice] = []
    @Published var selectedDeviceID: String?
    @Published var remoteEntries: [RemoteEntry] = []
    @Published var remotePath = "/sdcard/DCIM"
    @Published private(set) var remoteEntriesByDeviceID: [String: [RemoteEntry]] = [:]
    @Published private(set) var remotePathsByDeviceID: [String: String] = [:]
    @Published private(set) var androidMediaScopesByDeviceID: [String: AndroidMediaScope] = [:]
    @Published private(set) var refreshingDeviceIDs = Set<String>()
    @Published var localPath: URL
    @Published var localEntries: [LocalEntry] = []
    @Published var transfers: [TransferJob] = []
    @Published var statusMessage = "连接手机后点击刷新。"
    @Published var errorMessage: String?
    @Published var isRefreshing = false
    @Published private(set) var thumbnailLoadedCountsByDeviceID: [String: Int] = [:]
    @Published private(set) var thumbnailFailureCountsByDeviceID: [String: Int] = [:]
    @Published private(set) var firstThumbnailErrorsByDeviceID: [String: String] = [:]
    @Published var iPhoneMirrorQuality: IPhoneMirrorQuality
    @Published private(set) var iPhoneAirPlayName: String
    @Published var iPhonePeerToPeerEnabled: Bool
    @Published private(set) var iPhonePeerToPeerPIN: String
    @Published var iPhoneMirrorMode: IPhoneMirrorMode
    @Published private(set) var activeMirrorPlatform: PhonePlatform? = nil

    let androidService = AndroidADBService()
    let iosService = IOSMediaService()
    let mirroringService = ScreenMirroringService()
    let embeddedIPhoneMirrorService = EmbeddedIPhoneMirrorService()
    let mirrorCaptureService = MirrorCaptureService()
    let wirelessTransferService = WirelessTransferService()
    private lazy var iPhoneMirrorWindowService = IPhoneMirrorWindowService(
        mirrorService: embeddedIPhoneMirrorService
    )

    private var androidDevices: [PhoneDevice] = []
    private var deviceConnectionOrder: [String] = []
    private var pendingTransfers: [PendingTransfer] = []
    private var retryPayloads: [UUID: PendingTransfer] = [:]
    private var transferWorkerIsRunning = false
    private var pendingUploads: [PendingUpload] = []
    private var uploadRetryPayloads: [UUID: PendingUpload] = [:]
    private var uploadWorkerIsRunning = false
    private var activeAndroidMirrorDeviceID: String?
    private var activeAndroidTextReverse: (deviceID: String, port: Int)?
    private let thumbnailCache = NSCache<NSString, NSData>()
    private var thumbnailLoads: [String: Task<Data?, Never>] = [:]
    private let androidThumbnailLimiter = AndroidThumbnailLimiter(limit: 2)
    private var cancellables = Set<AnyCancellable>()

    init() {
        let fileManager = FileManager.default
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        let fallbackPath = pictures ?? fileManager.homeDirectoryForCurrentUser
        if let savedPath = UserDefaults.standard.string(forKey: Self.lastLocalDirectoryKey) {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: savedPath, isDirectory: &isDirectory), isDirectory.boolValue {
                localPath = URL(fileURLWithPath: savedPath, isDirectory: true)
            } else {
                localPath = fallbackPath
            }
        } else {
            localPath = fallbackPath
        }
        let savedMirrorQuality = UserDefaults.standard.string(forKey: Self.iPhoneMirrorQualityKey)
        iPhoneMirrorQuality = savedMirrorQuality.flatMap(IPhoneMirrorQuality.init(rawValue:)) ?? .clear
        iPhoneAirPlayName = Self.normalizedAirPlayName(
            UserDefaults.standard.string(forKey: Self.iPhoneAirPlayNameKey) ?? "PhoneBridge"
        )
        iPhonePeerToPeerEnabled = UserDefaults.standard.bool(forKey: Self.iPhonePeerToPeerKey)
        iPhoneMirrorMode = IPhoneMirrorMode(
            rawValue: UserDefaults.standard.string(forKey: Self.iPhoneMirrorModeKey) ?? ""
        ) ?? .embedded
        if let savedPIN = UserDefaults.standard.string(forKey: Self.iPhonePeerToPeerPINKey),
           savedPIN.count == 4,
           savedPIN.allSatisfy(\.isNumber) {
            iPhonePeerToPeerPIN = savedPIN
        } else {
            iPhonePeerToPeerPIN = String(format: "%04d", Int.random(in: 0...9_999))
        }
        UserDefaults.standard.set(iPhoneAirPlayName, forKey: Self.iPhoneAirPlayNameKey)
        UserDefaults.standard.set(iPhonePeerToPeerPIN, forKey: Self.iPhonePeerToPeerPINKey)
        thumbnailCache.countLimit = 600
        thumbnailCache.totalCostLimit = 64 * 1024 * 1024

        iosService.onChange = { [weak self] in
            self?.mergeDevices()
            self?.refreshIOSWorkspaces()
        }
        iosService.onStatus = { [weak self] message in
            self?.statusMessage = message
        }
        mirroringService.onStatus = { [weak self] message in
            self?.statusMessage = message
        }
        mirroringService.onError = { [weak self] message in
            self?.errorMessage = message
            self?.statusMessage = message
        }
        mirroringService.onAndroidStopped = { [weak self] deviceID, _ in
            guard let self, self.activeAndroidMirrorDeviceID == deviceID else { return }
            self.activeAndroidMirrorDeviceID = nil
            if self.activeMirrorPlatform == .android { self.activeMirrorPlatform = nil }
        }
        mirroringService.onIPhoneStopped = { [weak self] _ in
            guard let self else { return }
            self.iPhoneMirrorWindowService.close()
            self.embeddedIPhoneMirrorService.stop()
            if self.activeMirrorPlatform == .ios { self.activeMirrorPlatform = nil }
        }
        embeddedIPhoneMirrorService.onStatus = { [weak self] message in
            self?.statusMessage = message
        }
        mirrorCaptureService.onStatus = { [weak self] message in
            self?.statusMessage = message
        }
        mirrorCaptureService.onError = { [weak self] message in
            self?.errorMessage = message
            self?.statusMessage = message
        }
        mirrorCaptureService.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        wirelessTransferService.onStatus = { [weak self] message in
            self?.statusMessage = message
        }
        wirelessTransferService.onFilesReceived = { [weak self] in
            self?.refreshLocal()
        }
        iosService.start()
        refreshLocal()

        Task {
            await refreshDevices(restartIOSDiscovery: false)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refreshAndroidDevices(silent: true)
            }
        }
    }

    func refreshDevices(restartIOSDiscovery: Bool = true) async {
        isRefreshing = true
        if restartIOSDiscovery {
            await iosService.refreshDiscovery()
        }
        androidService.refreshADBLocation()
        await refreshAndroidDevices(silent: false)
        mergeDevices()
        for device in devices {
            await refreshRemote(deviceID: device.id)
        }
        isRefreshing = false
    }

    func selectDevice(_ id: String?) {
        selectedDeviceID = id
        guard let id, let device = devices.first(where: { $0.id == id }) else {
            remoteEntries = []
            return
        }
        remotePath = remotePath(for: id)
        remoteEntries = remoteEntries(for: id)
        if remoteEntries.isEmpty {
            Task { await refreshRemote(deviceID: device.id) }
        }
    }

    func refreshRemote() async {
        guard let id = selectedDeviceID else {
            remoteEntries = []
            return
        }
        await refreshRemote(deviceID: id)
    }

    func refreshRemote(deviceID: String) async {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return }
        guard !refreshingDeviceIDs.contains(deviceID) else { return }
        refreshingDeviceIDs.insert(deviceID)
        defer { refreshingDeviceIDs.remove(deviceID) }

        do {
            let entries: [RemoteEntry]
            switch device.platform {
            case .android:
                switch androidMediaScope(for: device.id) {
                case .folder:
                    entries = try await androidService.entries(
                        deviceID: device.id,
                        at: remotePathsByDeviceID[device.id] ?? "/sdcard/DCIM"
                    )
                    statusMessage = "\(device.name)：\(entries.count) 个项目"
                case .images:
                    entries = try await androidService.mediaEntries(deviceID: device.id, kind: .image)
                    statusMessage = "\(device.name)：自动找到 \(entries.count) 张照片"
                case .videos:
                    entries = try await androidService.mediaEntries(deviceID: device.id, kind: .video)
                    statusMessage = "\(device.name)：自动找到 \(entries.count) 个视频"
                }
            case .ios:
                entries = iosService.entries(deviceID: device.id)
                statusMessage = "\(device.name)：\(entries.count) 个照片或视频"
            }
            remoteEntriesByDeviceID[device.id] = entries
            if selectedDeviceID == device.id {
                remoteEntries = entries
                remotePath = remotePath(for: device.id)
            }
        } catch {
            show(error)
        }
    }

    func openRemoteDirectory(_ entry: RemoteEntry) {
        openRemoteDirectory(entry, deviceID: entry.deviceID)
    }

    func openRemoteDirectory(_ entry: RemoteEntry, deviceID: String) {
        guard entry.platform == .android, entry.isDirectory else { return }
        androidMediaScopesByDeviceID[deviceID] = .folder
        remotePathsByDeviceID[deviceID] = entry.remotePath
        if selectedDeviceID == deviceID { remotePath = entry.remotePath }
        Task { await refreshRemote(deviceID: deviceID) }
    }

    func remoteParent() {
        guard let id = selectedDeviceID else { return }
        remoteParent(deviceID: id)
    }

    func remoteParent(deviceID: String) {
        guard devices.first(where: { $0.id == deviceID })?.platform == .android else { return }
        if androidMediaScope(for: deviceID) != .folder {
            androidMediaScopesByDeviceID[deviceID] = .folder
            remotePathsByDeviceID[deviceID] = "/sdcard/DCIM"
            if selectedDeviceID == deviceID { remotePath = "/sdcard/DCIM" }
            Task { await refreshRemote(deviceID: deviceID) }
            return
        }
        let current = remotePathsByDeviceID[deviceID] ?? "/sdcard/DCIM"
        guard current != "/" else { return }
        let parent = (current as NSString).deletingLastPathComponent
        let next = parent.isEmpty ? "/" : parent
        remotePathsByDeviceID[deviceID] = next
        if selectedDeviceID == deviceID { remotePath = next }
        Task { await refreshRemote(deviceID: deviceID) }
    }

    func navigateRemote(to path: String, deviceID: String) {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return }
        guard device.platform == .android else { return }
        if path == "/媒体库/照片（自动扫描）" {
            setAndroidMediaScope(.images, deviceID: deviceID)
            return
        }
        if path == "/媒体库/视频（自动扫描）" {
            setAndroidMediaScope(.videos, deviceID: deviceID)
            return
        }
        guard path.hasPrefix("/"), !path.hasPrefix("/媒体库") else { return }
        androidMediaScopesByDeviceID[deviceID] = .folder
        remotePathsByDeviceID[deviceID] = path
        if selectedDeviceID == deviceID { remotePath = path }
        Task { await refreshRemote(deviceID: deviceID) }
    }

    func remoteEntries(for deviceID: String) -> [RemoteEntry] {
        remoteEntriesByDeviceID[deviceID] ?? []
    }

    func remotePath(for deviceID: String) -> String {
        if let virtualPath = androidMediaScope(for: deviceID).displayPath {
            return virtualPath
        }
        if let path = remotePathsByDeviceID[deviceID] { return path }
        return devices.first(where: { $0.id == deviceID })?.platform == .ios ? "/照片与视频" : "/sdcard/DCIM"
    }

    func androidMediaScope(for deviceID: String) -> AndroidMediaScope {
        androidMediaScopesByDeviceID[deviceID] ?? .folder
    }

    func setAndroidMediaScope(_ scope: AndroidMediaScope, deviceID: String) {
        guard devices.first(where: { $0.id == deviceID })?.platform == .android else { return }
        guard androidMediaScope(for: deviceID) != scope else { return }
        androidMediaScopesByDeviceID[deviceID] = scope
        if selectedDeviceID == deviceID { remotePath = remotePath(for: deviceID) }
        Task { await refreshRemote(deviceID: deviceID) }
    }

    func isRefreshing(deviceID: String) -> Bool {
        refreshingDeviceIDs.contains(deviceID)
    }

    func moveDevicePanel(_ sourceID: String, before targetID: String) {
        guard sourceID != targetID,
              let sourceIndex = deviceConnectionOrder.firstIndex(of: sourceID),
              let targetIndex = deviceConnectionOrder.firstIndex(of: targetID) else { return }
        let moved = deviceConnectionOrder.remove(at: sourceIndex)
        let insertionIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        deviceConnectionOrder.insert(moved, at: insertionIndex)
        rebuildOrderedDevices()
        statusMessage = "已调整设备面板顺序。"
    }

    func refreshLocal() {
        do {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: localPath,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants]
            )
            localEntries = urls.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys), values.isHidden != true else { return nil }
                return LocalEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: values.isDirectory == true,
                    size: Int64(values.fileSize ?? 0),
                    modifiedAt: values.contentModificationDate
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        } catch {
            show(error)
        }
    }

    func openLocalDirectory(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        localPath = url
        UserDefaults.standard.set(url.path, forKey: Self.lastLocalDirectoryKey)
        refreshLocal()
    }

    func openLocalEntry(_ entry: LocalEntry) {
        if entry.isDirectory {
            openLocalDirectory(entry.url)
            return
        }

        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            errorMessage = "文件已不存在，请刷新左侧目录。"
            statusMessage = errorMessage ?? "文件已不存在。"
            return
        }

        guard NSWorkspace.shared.open(entry.url) else {
            errorMessage = "无法打开“\(entry.name)”，请确认 Mac 上有支持此格式的应用。"
            statusMessage = errorMessage ?? "无法打开文件。"
            return
        }
        statusMessage = "已打开：\(entry.name)"
    }

    func revealInFinder(_ entry: LocalEntry) {
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            errorMessage = "文件已不存在，请刷新左侧目录。"
            statusMessage = errorMessage ?? "文件已不存在。"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        statusMessage = "已在 Finder 中显示：\(entry.name)"
    }

    var canPasteLocalItems: Bool {
        !localPasteboardURLs().isEmpty
    }

    func copyLocalEntry(_ entry: LocalEntry) {
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            errorMessage = "文件已不存在，请刷新左侧目录。"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([entry.url as NSURL]) else {
            errorMessage = "无法拷贝“\(entry.name)”到剪贴板。"
            return
        }
        statusMessage = "已拷贝：\(entry.name)"
    }

    func pasteLocalItems() {
        let sources = localPasteboardURLs()
        guard !sources.isEmpty else {
            errorMessage = "剪贴板中没有可粘贴的文件或文件夹。"
            return
        }

        var copiedCount = 0
        var failures: [String] = []
        for source in sources {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
                failures.append("\(source.lastPathComponent)：源项目已不存在")
                continue
            }

            let sourcePath = source.standardizedFileURL.path
            let targetDirectoryPath = localPath.standardizedFileURL.path
            if isDirectory.boolValue,
               (targetDirectoryPath == sourcePath || targetDirectoryPath.hasPrefix(sourcePath + "/")) {
                failures.append("\(source.lastPathComponent)：不能粘贴到自身或其子目录")
                continue
            }

            let destination = uniqueLocalCopyDestination(
                for: source,
                in: localPath,
                isDirectory: isDirectory.boolValue
            )
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                copiedCount += 1
            } catch {
                failures.append("\(source.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        refreshLocal()
        if failures.isEmpty {
            statusMessage = "已粘贴 \(copiedCount) 个项目。"
        } else {
            statusMessage = "已粘贴 \(copiedCount) 个，失败 \(failures.count) 个。"
            errorMessage = failures.prefix(3).joined(separator: "\n")
        }
    }

    func promptAndCreateLocalFolder() {
        guard let name = promptForLocalItemName(
            title: "新建文件夹",
            message: "请输入文件夹名称。",
            defaultName: uniqueSuggestedName(base: "未命名文件夹")
        ) else { return }
        let destination = localPath.appendingPathComponent(name, isDirectory: true)
        guard validateNewLocalItem(name: name, destination: destination) else { return }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            refreshLocal()
            statusMessage = "已新建文件夹：\(name)"
        } catch {
            show(error)
        }
    }

    func promptAndCreateLocalFile() {
        guard let name = promptForLocalItemName(
            title: "新建文件",
            message: "请输入文件名，可包含扩展名。",
            defaultName: uniqueSuggestedName(base: "未命名文件.txt")
        ) else { return }
        let destination = localPath.appendingPathComponent(name, isDirectory: false)
        guard validateNewLocalItem(name: name, destination: destination) else { return }
        guard FileManager.default.createFile(atPath: destination.path, contents: Data()) else {
            errorMessage = "无法新建文件“\(name)”。"
            return
        }
        refreshLocal()
        statusMessage = "已新建文件：\(name)"
    }

    func moveLocalEntryToTrash(_ entry: LocalEntry) {
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            errorMessage = "文件已不存在，请刷新左侧目录。"
            statusMessage = errorMessage ?? "文件已不存在。"
            return
        }

        NSWorkspace.shared.recycle([entry.url]) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.show(error)
                } else {
                    self.refreshLocal()
                    self.statusMessage = "已移到废纸篓：\(entry.name)"
                }
            }
        }
    }

    func startUSBScreenMirroring() {
        guard let device = selectedDevice else {
            errorMessage = "请先连接并选择一台手机。"
            return
        }
        switch device.platform {
        case .android:
            activeMirrorPlatform = .android
            startAndroidMirroring(device: device)
        case .ios:
            startIPhoneMirroring()
        }
    }

    private func startAndroidMirroring(device: PhoneDevice) {
        guard mirroringService.startAndroid(device: device) != nil else {
            if activeMirrorPlatform == .android { activeMirrorPlatform = nil }
            return
        }
        activeAndroidMirrorDeviceID = device.id
    }

    func stopSelectedAndroidMirroring() {
        guard let deviceID = selectedDeviceID, selectedDevice?.platform == .android else { return }
        if mirrorCaptureService.isRecording { stopMirrorRecording() }
        mirroringService.stopAndroid(deviceID: deviceID)
        if activeAndroidMirrorDeviceID == deviceID { activeAndroidMirrorDeviceID = nil }
        if activeMirrorPlatform == .android { activeMirrorPlatform = nil }
        statusMessage = "正在停止 Android 投屏…"
    }

    func stopCurrentEmbeddedMirroring() {
        stopIPhoneMirroring()
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func startIPhoneMirroring(allowWithoutConnectedDevice: Bool = false) {
        if !allowWithoutConnectedDevice,
           selectedDevice?.platform != .ios,
           activeMirrorPlatform != .ios {
            errorMessage = "请先选择 iPhone，或从“无线连接”直接启动 AirPlay 接收器。"
            return
        }
        activeMirrorPlatform = .ios
        if mirroringService.iPhoneAirPlayProcessID != nil {
            stopIPhoneMirroring()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.launchIPhoneAirPlay()
            }
            return
        }
        launchIPhoneAirPlay()
    }

    private func launchIPhoneAirPlay() {
        embeddedIPhoneMirrorService.markStartingAirPlayReceiver()
        guard let streamPort = embeddedIPhoneMirrorService.startFrameReceiver() else { return }
        if iPhoneMirrorMode == .embedded {
            iPhoneMirrorWindowService.close()
        }
        guard mirroringService.startIPhoneAirPlay(
            streamPort: streamPort,
            quality: iPhoneMirrorQuality,
            receiverName: iPhoneAirPlayName,
            mode: iPhoneMirrorMode,
            peerToPeer: iPhonePeerToPeerEnabled,
            pin: iPhonePeerToPeerEnabled ? iPhonePeerToPeerPIN : nil
        ) != nil else {
            iPhoneMirrorWindowService.close()
            embeddedIPhoneMirrorService.stop()
            return
        }
        if iPhoneMirrorMode == .separateWindow {
            iPhoneMirrorWindowService.show(receiverName: iPhoneAirPlayName)
        }
    }

    func showIPhoneMirrorWindow() {
        guard iPhoneMirrorMode == .separateWindow,
              mirroringService.iPhoneAirPlayProcessID != nil else {
            statusMessage = "请先以独立窗口模式启动 AirPlay 接收器。"
            return
        }
        iPhoneMirrorWindowService.show(receiverName: iPhoneAirPlayName)
        statusMessage = "iPhone 独立投屏窗口已显示。"
    }

    func setIPhoneMirrorMode(_ mode: IPhoneMirrorMode) {
        guard iPhoneMirrorMode != mode else { return }
        iPhoneMirrorMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.iPhoneMirrorModeKey)
        if mirroringService.iPhoneAirPlayProcessID != nil {
            stopIPhoneMirroring()
            statusMessage = "已切换为“\(mode.label)”，请重新点击启动投屏。"
        } else {
            statusMessage = "iPhone 投屏已切换为“\(mode.label)”。"
        }
    }

    func setIPhoneMirrorQuality(_ quality: IPhoneMirrorQuality) {
        guard iPhoneMirrorQuality != quality else { return }
        iPhoneMirrorQuality = quality
        UserDefaults.standard.set(quality.rawValue, forKey: Self.iPhoneMirrorQualityKey)
        statusMessage = "iPhone 投屏已切换为“\(quality.label)”。"
        if mirroringService.iPhoneAirPlayProcessID != nil {
            restartIPhoneMirroring()
        }
    }

    @discardableResult
    func setIPhoneAirPlayName(_ name: String) -> String {
        let normalized = Self.normalizedAirPlayName(name)
        guard normalized != iPhoneAirPlayName else {
            statusMessage = "AirPlay 接收名称保持为“\(normalized)”。"
            return normalized
        }
        iPhoneAirPlayName = normalized
        UserDefaults.standard.set(normalized, forKey: Self.iPhoneAirPlayNameKey)
        statusMessage = "AirPlay 接收名称已改为“\(normalized)”。"
        if mirroringService.iPhoneAirPlayProcessID != nil {
            restartIPhoneMirroring()
        }
        return normalized
    }

    func setIPhonePeerToPeerEnabled(_ enabled: Bool) {
        guard iPhonePeerToPeerEnabled != enabled else { return }
        iPhonePeerToPeerEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.iPhonePeerToPeerKey)
        statusMessage = enabled
            ? "已开启附近设备投屏；连接时请输入 PIN \(iPhonePeerToPeerPIN)。"
            : "已切换为普通局域网 AirPlay。"
        if mirroringService.iPhoneAirPlayProcessID != nil {
            restartIPhoneMirroring()
        }
    }

    func regenerateIPhonePeerToPeerPIN() {
        iPhonePeerToPeerPIN = String(format: "%04d", Int.random(in: 0...9_999))
        UserDefaults.standard.set(iPhonePeerToPeerPIN, forKey: Self.iPhonePeerToPeerPINKey)
        statusMessage = "附近投屏 PIN 已更新为 \(iPhonePeerToPeerPIN)。"
        if iPhonePeerToPeerEnabled, mirroringService.iPhoneAirPlayProcessID != nil {
            restartIPhoneMirroring()
        }
    }

    func pairAndroidWirelessly(endpoint: String, code: String) async {
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidADBEndpoint(normalizedEndpoint),
              normalizedCode.count == 6,
              normalizedCode.allSatisfy(\.isNumber) else {
            errorMessage = "请输入手机“无线调试”页面显示的配对地址（IP:端口）和 6 位配对码。"
            return
        }
        do {
            statusMessage = "正在无线配对 Android…"
            statusMessage = try await androidService.pair(endpoint: normalizedEndpoint, code: normalizedCode)
        } catch {
            show(error)
        }
    }

    func connectAndroidWirelessly(endpoint: String) async {
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidADBEndpoint(normalizedEndpoint) else {
            errorMessage = "请输入手机“无线调试”页面显示的连接地址（IP:端口）。"
            return
        }
        do {
            statusMessage = "正在连接无线 Android…"
            statusMessage = try await androidService.connect(endpoint: normalizedEndpoint)
            await refreshDevices(restartIOSDiscovery: false)
        } catch {
            show(error)
        }
    }

    func disconnectAndroidWirelessly(endpoint: String) async {
        do {
            statusMessage = try await androidService.disconnect(endpoint: endpoint)
            await refreshDevices(restartIOSDiscovery: false)
        } catch {
            show(error)
        }
    }

    func restartIPhoneMirroring() {
        guard activeMirrorPlatform == .ios || selectedDevice?.platform == .ios else { return }
        startIPhoneMirroring(allowWithoutConnectedDevice: true)
    }

    func stopIPhoneMirroring() {
        if mirrorCaptureService.isRecording { stopMirrorRecording() }
        mirroringService.stopIPhoneAirPlay()
        iPhoneMirrorWindowService.close()
        embeddedIPhoneMirrorService.stop()
        if activeMirrorPlatform == .ios { activeMirrorPlatform = nil }
    }

    func captureMirrorScreenshot() {
        guard let source = currentMirrorCaptureSource() else {
            errorMessage = "请先启动投屏并等待手机画面出现。"
            statusMessage = errorMessage ?? "投屏尚未启动。"
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let image = try await self.mirrorCaptureService.captureFrame(from: source)
                let representation = NSBitmapImageRep(cgImage: image)
                guard let data = representation.representation(using: .png, properties: [:]) else {
                    throw PhoneBridgeError.commandFailed("无法生成 PNG 截图。")
                }

                let panel = NSSavePanel()
                panel.title = "保存投屏截图"
                panel.prompt = "保存"
                panel.allowedContentTypes = [.png]
                panel.canCreateDirectories = true
                panel.directoryURL = self.lastMirrorCaptureDirectory()
                panel.nameFieldStringValue = "PhoneBridge-截图-\(Self.mirrorCaptureTimestamp()).png"
                guard panel.runModal() == .OK, let destination = panel.url else {
                    self.statusMessage = "已取消保存截图。"
                    return
                }
                try data.write(to: destination, options: .atomic)
                self.rememberMirrorCaptureDirectory(destination.deletingLastPathComponent())
                self.statusMessage = "截图已保存：\(destination.lastPathComponent)"
            } catch {
                self.show(error)
            }
        }
    }

    func startMirrorRecording() {
        guard let source = currentMirrorCaptureSource() else {
            errorMessage = "请先启动投屏并等待手机画面出现。"
            statusMessage = errorMessage ?? "投屏尚未启动。"
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.mirrorCaptureService.startRecording(from: source)
            } catch {
                self.show(error)
            }
        }
    }

    func stopMirrorRecording() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard try await self.mirrorCaptureService.stopRecording() != nil else { return }
                self.savePendingMirrorRecording()
            } catch {
                self.show(error)
            }
        }
    }

    func savePendingMirrorRecording() {
        guard let source = mirrorCaptureService.pendingRecordingURL else {
            statusMessage = "没有待保存的录屏。"
            return
        }

        let preferredName = mirrorCaptureService.pendingRecordingFilename
            ?? "PhoneBridge-录屏-\(Self.mirrorCaptureTimestamp()).mp4"
        let panel = NSSavePanel()
        panel.title = "命名并保存录屏"
        panel.message = "可以修改文件名并选择保存位置；下次会默认打开此文件夹。"
        panel.prompt = "保存"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = lastMirrorCaptureDirectory()
        panel.nameFieldStringValue = preferredName
        guard panel.runModal() == .OK, let destination = panel.url else {
            statusMessage = "已保留本次录屏；点击“保存录像”可再次命名并选择位置。"
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
            } else {
                try FileManager.default.moveItem(at: source, to: destination)
            }
            mirrorCaptureService.markPendingRecordingSaved()
            rememberMirrorCaptureDirectory(destination.deletingLastPathComponent())
            statusMessage = "录屏已保存：\(destination.lastPathComponent)"
        } catch {
            show(error)
        }
    }

    private func currentMirrorCaptureSource() -> MirrorCaptureSource? {
        switch activeMirrorPlatform ?? selectedDevice?.platform {
        case .ios:
            return .embedded { [weak self] in self?.embeddedIPhoneMirrorService.latestFrame }

        case .android:
            let deviceID = activeAndroidMirrorDeviceID ?? selectedDeviceID
            guard let deviceID else { return nil }
            guard let processID = mirroringService.androidMirrorProcessID(deviceID: deviceID) else { return nil }
            return .separateWindow(processID: processID)

        case nil:
            return nil
        }
    }

    private func lastMirrorCaptureDirectory() -> URL {
        if let savedPath = UserDefaults.standard.string(forKey: Self.lastMirrorCaptureDirectoryKey) {
            let savedURL = URL(fileURLWithPath: savedPath, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: savedURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return savedURL
            }
        }
        return localPath
    }

    private func rememberMirrorCaptureDirectory(_ directory: URL) {
        UserDefaults.standard.set(directory.path, forKey: Self.lastMirrorCaptureDirectoryKey)
    }

    private static func mirrorCaptureTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    func localParent() {
        openLocalDirectory(localPath.deletingLastPathComponent())
    }

    func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = localPath
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            openLocalDirectory(url)
        }
    }

    @discardableResult
    func chooseAndSendFiles(to deviceID: String) -> Bool {
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            errorMessage = "手机已断开，请刷新设备后重试。"
            return false
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = localPath
        panel.prompt = "选择并传输"

        if device.platform == .android {
            let targetSelector = makeAndroidDestinationSelector(deviceID: deviceID)
            panel.accessoryView = targetSelector.container
            guard panel.runModal() == .OK else { return false }
            let targetDirectory = normalizedAndroidDirectory(targetSelector.comboBox.stringValue)
            guard let targetDirectory else {
                errorMessage = "手机目标文件夹必须是以 / 开头的有效 Android 路径。"
                return false
            }
            sendFilesToAndroid(panel.urls, deviceID: deviceID, remoteDirectory: targetDirectory)
            return false
        }

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return false }
        wirelessTransferService.start(destinationDirectory: localPath, sharedFiles: panel.urls)
        statusMessage = "已生成 iPhone 下载页，共 \(panel.urls.count) 个文件。"
        return true
    }

    func sendFilesToAndroid(
        _ urls: [URL],
        deviceID: String,
        remoteDirectory: String? = nil
    ) {
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        guard !files.isEmpty else { return }
        let targetDirectory = normalizedAndroidDirectory(remoteDirectory ?? currentAndroidUploadDirectory(deviceID: deviceID))
            ?? "/sdcard/Download/PhoneBridge"

        for source in files {
            let jobID = UUID()
            let size = ((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
            let remoteDestination = URL(fileURLWithPath: targetDirectory)
                .appendingPathComponent(source.lastPathComponent)
            let job = TransferJob(
                id: jobID,
                sourceName: "→ \(source.lastPathComponent)",
                destination: remoteDestination,
                totalBytes: size,
                progress: 0,
                state: .queued,
                startedAt: nil,
                estimatedRemaining: nil,
                bytesPerSecond: nil
            )
            let payload = PendingUpload(
                jobID: jobID,
                source: source,
                deviceID: deviceID,
                remoteDirectory: targetDirectory
            )
            transfers.append(job)
            pendingUploads.append(payload)
            uploadRetryPayloads[jobID] = payload
        }
        statusMessage = "已加入 \(files.count) 个任务，目标：\(targetDirectory)"
        startUploadWorkerIfNeeded()
    }

    @discardableResult
    func sendLocalFiles(_ urls: [URL], to deviceID: String) -> Bool {
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            errorMessage = "手机已断开，请刷新后重试。"
            return false
        }
        let files = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue
        }
        guard !files.isEmpty else {
            errorMessage = "目前只支持把 Mac 文件拖到手机，暂不支持直接传输文件夹。"
            return false
        }

        switch device.platform {
        case .android:
            sendFilesToAndroid(files, deviceID: deviceID, remoteDirectory: currentAndroidUploadDirectory(deviceID: deviceID))
            return false
        case .ios:
            wirelessTransferService.start(destinationDirectory: localPath, sharedFiles: files)
            statusMessage = "已生成 iPhone 下载页（\(files.count) 个文件）；请下载后选择“存储到文件”。"
            return true
        }
    }

    @discardableResult
    func chooseCertificateForWirelessTransfer() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["cer", "crt", "pem", "mobileconfig"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = localPath
        panel.prompt = "共享证书"
        guard panel.runModal() == .OK, let file = panel.url else { return false }
        wirelessTransferService.start(destinationDirectory: localPath, sharedFile: file)
        return true
    }

    func startWirelessTransferPortal(sharedFile: URL? = nil) {
        wirelessTransferService.start(destinationDirectory: localPath, sharedFile: sharedFile)
    }

    @discardableResult
    func startTextTransfer(_ text: String, targetDeviceID: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            errorMessage = "请先输入要发送的网站链接或文本。"
            return false
        }
        guard let targetDevice = devices.first(where: { $0.id == targetDeviceID }) else {
            errorMessage = "手机已断开，请刷新设备后重试。"
            return false
        }
        wirelessTransferService.start(
            destinationDirectory: localPath,
            sharedText: text,
            allowLoopbackFallback: targetDevice.platform == .android
        )
        statusMessage = "正在生成手机文本页面…"
        return true
    }

    func openTextTransferPageOnAndroid(deviceID: String) async -> URL? {
        guard devices.first(where: { $0.id == deviceID })?.platform == .android,
              let url = wirelessTransferService.primaryURL else { return nil }
        do {
            let openedURL = try await androidService.openPhoneBridgePage(
                deviceID: deviceID,
                networkURL: url
            )
            if let port = url.port, openedURL.host == "127.0.0.1" {
                activeAndroidTextReverse = (deviceID, port)
                statusMessage = "已通过 ADB 在 Android 上打开文本页面。"
            } else {
                statusMessage = "已在 Android 浏览器打开文本页面。"
            }
            return openedURL
        } catch {
            show(error)
            return nil
        }
    }

    func stopWirelessTransferPortal() {
        if let reverse = activeAndroidTextReverse {
            activeAndroidTextReverse = nil
            Task { [androidService] in
                await androidService.removeReverse(deviceID: reverse.deviceID, port: reverse.port)
            }
        }
        wirelessTransferService.stop()
    }

    func conflictingFilenames(_ entries: [RemoteEntry], in destinationDirectory: URL) -> [String] {
        var reservedPaths = Set<String>()
        var reportedNames = Set<String>()
        var conflicts: [String] = []

        for entry in entries where !entry.isDirectory {
            let destination = destinationDirectory.appendingPathComponent(entry.name)
            let pathKey = destinationKey(destination)
            let alreadyReserved = !reservedPaths.insert(pathKey).inserted
            if FileManager.default.fileExists(atPath: destination.path) || alreadyReserved {
                let nameKey = entry.name.lowercased()
                if reportedNames.insert(nameKey).inserted {
                    conflicts.append(entry.name)
                }
            }
        }
        return conflicts
    }

    func transfer(
        _ entries: [RemoteEntry],
        to destinationDirectory: URL,
        conflictPolicy: TransferConflictPolicy = .rename
    ) {
        let files = entries.filter { !$0.isDirectory }
        guard !files.isEmpty else { return }

        var reservedPaths = Set<String>()
        var queuedCount = 0
        var skippedCount = 0
        for entry in files {
            let original = destinationDirectory.appendingPathComponent(entry.name)
            let originalKey = destinationKey(original)
            let conflict = FileManager.default.fileExists(atPath: original.path) || reservedPaths.contains(originalKey)

            let destination: URL
            let overwriteExisting: Bool
            switch conflictPolicy {
            case .skip where conflict:
                skippedCount += 1
                continue
            case .rename where conflict:
                destination = uniqueDestination(
                    directory: destinationDirectory,
                    filename: entry.name,
                    reservedPaths: &reservedPaths
                )
                overwriteExisting = false
            case .overwrite where conflict:
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: original.path, isDirectory: &isDirectory)
                if exists && isDirectory.boolValue {
                    destination = uniqueDestination(
                        directory: destinationDirectory,
                        filename: entry.name,
                        reservedPaths: &reservedPaths
                    )
                    overwriteExisting = false
                } else {
                    destination = original
                    reservedPaths.insert(originalKey)
                    overwriteExisting = true
                }
            default:
                destination = original
                reservedPaths.insert(originalKey)
                overwriteExisting = false
            }

            let jobID = UUID()
            let job = TransferJob(
                id: jobID,
                sourceName: entry.name,
                destination: destination,
                totalBytes: entry.size,
                progress: 0,
                state: .queued,
                startedAt: nil,
                estimatedRemaining: nil,
                bytesPerSecond: nil
            )
            let payload = PendingTransfer(
                jobID: jobID,
                entry: entry,
                destination: destination,
                overwriteExisting: overwriteExisting
            )
            transfers.append(job)
            pendingTransfers.append(payload)
            retryPayloads[jobID] = payload
            queuedCount += 1
        }

        if skippedCount > 0 {
            statusMessage = "已加入 \(queuedCount) 个任务，跳过 \(skippedCount) 个同名文件。"
        } else if queuedCount > 0 {
            statusMessage = "已加入 \(queuedCount) 个传输任务。"
        }
        startTransferWorkerIfNeeded()
    }

    func retryTransfer(_ jobID: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == jobID }),
              case .failed = transfers[index].state else { return }

        if let upload = uploadRetryPayloads[jobID],
           !pendingUploads.contains(where: { $0.jobID == jobID }) {
            transfers[index].progress = 0
            transfers[index].state = .queued
            transfers[index].startedAt = nil
            transfers[index].estimatedRemaining = nil
            transfers[index].bytesPerSecond = nil
            pendingUploads.append(upload)
            statusMessage = "已重新加入：\(transfers[index].sourceName)"
            startUploadWorkerIfNeeded()
            return
        }

        guard let payload = retryPayloads[jobID],
              !pendingTransfers.contains(where: { $0.jobID == jobID }) else { return }

        transfers[index].progress = 0
        transfers[index].state = .queued
        transfers[index].startedAt = nil
        transfers[index].estimatedRemaining = nil
        transfers[index].bytesPerSecond = nil
        pendingTransfers.append(payload)
        statusMessage = "已重新加入：\(transfers[index].sourceName)"
        startTransferWorkerIfNeeded()
    }

    func clearFinishedTransfers() {
        let completedIDs = Set(transfers.compactMap { job -> UUID? in
            if case .completed = job.state { return job.id }
            return nil
        })
        transfers.removeAll { completedIDs.contains($0.id) }
        for id in completedIDs {
            retryPayloads.removeValue(forKey: id)
            uploadRetryPayloads.removeValue(forKey: id)
        }
    }

    func thumbnailData(for entry: RemoteEntry) async -> Data? {
        guard !entry.isDirectory else { return nil }
        let key = entry.id as NSString
        if let cached = thumbnailCache.object(forKey: key) {
            return cached as Data
        }
        if let activeLoad = thumbnailLoads[entry.id] {
            return await activeLoad.value
        }

        let load = Task<Data?, Never> { [weak self] in
            guard let self else { return nil }
            do {
                switch entry.platform {
                case .ios:
                    return try await self.iosService.thumbnailData(entryID: entry.id)
                case .android:
                    await self.androidThumbnailLimiter.acquire()
                    do {
                        let data = try await self.androidService.thumbnailData(for: entry)
                        await self.androidThumbnailLimiter.release()
                        return data
                    } catch {
                        await self.androidThumbnailLimiter.release()
                        throw error
                    }
                }
            } catch {
                if self.firstThumbnailErrorsByDeviceID[entry.deviceID] == nil {
                    self.firstThumbnailErrorsByDeviceID[entry.deviceID] = error.localizedDescription
                }
                return nil
            }
        }
        thumbnailLoads[entry.id] = load
        let image = await load.value
        thumbnailLoads.removeValue(forKey: entry.id)
        if let image {
            thumbnailCache.setObject(image as NSData, forKey: key, cost: max(1, image.count))
            thumbnailLoadedCountsByDeviceID[entry.deviceID, default: 0] += 1
        } else {
            thumbnailFailureCountsByDeviceID[entry.deviceID, default: 0] += 1
        }
        return image
    }

    func thumbnailLoadedCount(for deviceID: String) -> Int {
        thumbnailLoadedCountsByDeviceID[deviceID] ?? 0
    }

    func thumbnailFailureCount(for deviceID: String) -> Int {
        thumbnailFailureCountsByDeviceID[deviceID] ?? 0
    }

    func firstThumbnailError(for deviceID: String) -> String? {
        firstThumbnailErrorsByDeviceID[deviceID]
    }

    var selectedDevice: PhoneDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    private func refreshAndroidDevices(silent: Bool) async {
        do {
            androidDevices = try await androidService.devices()
            mergeDevices()
        } catch PhoneBridgeError.adbNotFound {
            androidDevices = []
            mergeDevices()
            if !silent { statusMessage = PhoneBridgeError.adbNotFound.localizedDescription }
        } catch {
            if !silent { show(error) }
        }
    }

    private func mergeDevices() {
        let discovered = androidDevices + iosService.devices
        let discoveredIDs = Set(discovered.map(\.id))
        deviceConnectionOrder.removeAll { !discoveredIDs.contains($0) }

        var newlyConnected: [String] = []
        for device in discovered where !deviceConnectionOrder.contains(device.id) {
            deviceConnectionOrder.append(device.id)
            newlyConnected.append(device.id)
            remotePathsByDeviceID[device.id] = device.platform == .ios ? "/照片与视频" : "/sdcard/DCIM"
            if device.platform == .android {
                androidMediaScopesByDeviceID[device.id] = .folder
            }
        }
        remoteEntriesByDeviceID = remoteEntriesByDeviceID.filter { discoveredIDs.contains($0.key) }
        remotePathsByDeviceID = remotePathsByDeviceID.filter { discoveredIDs.contains($0.key) }
        androidMediaScopesByDeviceID = androidMediaScopesByDeviceID.filter { discoveredIDs.contains($0.key) }
        thumbnailLoadedCountsByDeviceID = thumbnailLoadedCountsByDeviceID.filter { discoveredIDs.contains($0.key) }
        thumbnailFailureCountsByDeviceID = thumbnailFailureCountsByDeviceID.filter { discoveredIDs.contains($0.key) }
        firstThumbnailErrorsByDeviceID = firstThumbnailErrorsByDeviceID.filter { discoveredIDs.contains($0.key) }
        rebuildOrderedDevices(from: discovered)

        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = devices.first?.id
            if let id = selectedDeviceID {
                remotePath = remotePath(for: id)
                remoteEntries = remoteEntries(for: id)
            }
        }

        for id in newlyConnected {
            Task { await refreshRemote(deviceID: id) }
        }
    }

    private func rebuildOrderedDevices(from discovered: [PhoneDevice]? = nil) {
        let source = discovered ?? (androidDevices + iosService.devices)
        let byID = Dictionary(uniqueKeysWithValues: source.map { ($0.id, $0) })
        devices = deviceConnectionOrder.compactMap { byID[$0] }
    }

    private func refreshIOSWorkspaces() {
        for device in devices where device.platform == .ios {
            remoteEntriesByDeviceID[device.id] = iosService.entries(deviceID: device.id)
        }
        if let id = selectedDeviceID,
           devices.first(where: { $0.id == id })?.platform == .ios {
            remoteEntries = remoteEntries(for: id)
            remotePath = remotePath(for: id)
        }
    }

    private func execute(_ transfer: PendingTransfer) async {
        let jobID = transfer.jobID
        let entry = transfer.entry
        let destination = transfer.destination
        let staging = stagingURL(for: destination, jobID: jobID)

        try? FileManager.default.removeItem(at: staging)
        updateJob(jobID) {
            $0.state = .running
            $0.progress = 0
            $0.startedAt = Date()
            $0.estimatedRemaining = nil
            $0.bytesPerSecond = nil
        }

        do {
            let progress: (Double) -> Void = { [weak self] value in
                Task { @MainActor in
                    self?.recordProgress(jobID: jobID, value: value)
                }
            }

            switch entry.platform {
            case .android:
                try await androidService.pull(
                    deviceID: entry.deviceID,
                    remotePath: entry.remotePath,
                    destination: staging,
                    expectedSize: entry.size,
                    onProgress: progress
                )
            case .ios:
                try await iosService.download(
                    entryID: entry.id,
                    destinationDirectory: staging.deletingLastPathComponent(),
                    filename: staging.lastPathComponent,
                    onProgress: progress
                )
            }

            try commit(
                staging: staging,
                to: destination,
                overwriteExisting: transfer.overwriteExisting
            )
            let didSetTransferDate = (try? FileManager.default.setAttributes(
                [.modificationDate: Date()],
                ofItemAtPath: destination.path
            )) != nil

            updateJob(jobID) {
                $0.progress = 1
                $0.state = .completed
                $0.estimatedRemaining = 0
            }
            if destination.deletingLastPathComponent() == localPath {
                refreshLocal()
            }
            statusMessage = didSetTransferDate
                ? "已传输：\(entry.name)（日期已更新为完成时间）"
                : "已传输：\(entry.name)，但无法更新修改日期。"
        } catch {
            try? FileManager.default.removeItem(at: staging)
            updateJob(jobID) {
                $0.state = .failed(error.localizedDescription)
                $0.estimatedRemaining = nil
                $0.bytesPerSecond = nil
            }
            statusMessage = "传输失败：\(entry.name)。可在任务列表中重试。"
        }
    }

    private func startTransferWorkerIfNeeded() {
        guard !transferWorkerIsRunning else { return }
        transferWorkerIsRunning = true
        Task {
            while !pendingTransfers.isEmpty {
                let next = pendingTransfers.removeFirst()
                await execute(next)
            }
            transferWorkerIsRunning = false
        }
    }

    private func startUploadWorkerIfNeeded() {
        guard !uploadWorkerIsRunning else { return }
        uploadWorkerIsRunning = true
        Task {
            while !pendingUploads.isEmpty {
                let next = pendingUploads.removeFirst()
                await executeUpload(next)
            }
            uploadWorkerIsRunning = false
        }
    }

    private func executeUpload(_ upload: PendingUpload) async {
        updateJob(upload.jobID) {
            $0.state = .running
            $0.progress = 0
            $0.startedAt = Date()
            $0.estimatedRemaining = nil
            $0.bytesPerSecond = nil
        }

        do {
            try await androidService.push(
                deviceID: upload.deviceID,
                source: upload.source,
                remoteDirectory: upload.remoteDirectory
            ) { [weak self] value in
                Task { @MainActor in
                    self?.recordProgress(jobID: upload.jobID, value: value)
                }
            }
            updateJob(upload.jobID) {
                $0.progress = 1
                $0.state = .completed
                $0.estimatedRemaining = 0
            }
            statusMessage = "已传输到 Android：\(upload.remoteDirectory)/\(upload.source.lastPathComponent)"
        } catch {
            updateJob(upload.jobID) {
                $0.state = .failed(error.localizedDescription)
                $0.estimatedRemaining = nil
                $0.bytesPerSecond = nil
            }
            statusMessage = "传输到 Android 失败：\(upload.source.lastPathComponent)。可在任务列表中重试。"
        }
    }

    private func updateJob(_ id: UUID, mutation: (inout TransferJob) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        mutation(&transfers[index])
    }

    private func recordProgress(jobID: UUID, value: Double) {
        let now = Date()
        updateJob(jobID) { job in
            guard case .running = job.state else { return }
            let progress = max(job.progress, min(1, max(0, value)))
            job.progress = progress

            guard progress > 0,
                  progress < 1,
                  job.totalBytes > 0,
                  let startedAt = job.startedAt else { return }
            let elapsed = now.timeIntervalSince(startedAt)
            guard elapsed >= 0.5 else { return }
            let bytesPerSecond = Double(job.totalBytes) * progress / elapsed
            guard bytesPerSecond > 0 else { return }
            job.bytesPerSecond = bytesPerSecond
            job.estimatedRemaining = Double(job.totalBytes) * (1 - progress) / bytesPerSecond
        }
    }

    private func commit(staging: URL, to destination: URL, overwriteExisting: Bool) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            guard overwriteExisting else {
                throw PhoneBridgeError.destinationAlreadyExists(destination.lastPathComponent)
            }
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: staging,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    private func stagingURL(for destination: URL, jobID: UUID) -> URL {
        let extensionName = destination.pathExtension
        let suffix = extensionName.isEmpty ? "" : ".\(extensionName)"
        return destination.deletingLastPathComponent()
            .appendingPathComponent(".phonebridge-\(jobID.uuidString).part\(suffix)")
    }

    private func uniqueDestination(
        directory: URL,
        filename: String,
        reservedPaths: inout Set<String>
    ) -> URL {
        let original = directory.appendingPathComponent(filename)
        let originalKey = destinationKey(original)
        if !FileManager.default.fileExists(atPath: original.path), !reservedPaths.contains(originalKey) {
            reservedPaths.insert(originalKey)
            return original
        }

        let extensionName = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var index = 1
        while true {
            let candidateName = extensionName.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(extensionName)"
            let candidate = directory.appendingPathComponent(candidateName)
            let candidateKey = destinationKey(candidate)
            if !FileManager.default.fileExists(atPath: candidate.path), !reservedPaths.contains(candidateKey) {
                reservedPaths.insert(candidateKey)
                return candidate
            }
            index += 1
        }
    }

    private func localPasteboardURLs() -> [URL] {
        let objects = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        var seen = Set<String>()
        return objects.compactMap { object in
            guard let nsURL = object as? NSURL, nsURL.isFileURL else { return nil }
            let url = nsURL as URL
            let key = url.standardizedFileURL.path
            return seen.insert(key).inserted ? url : nil
        }
    }

    private func currentAndroidUploadDirectory(deviceID: String) -> String {
        guard androidMediaScope(for: deviceID) == .folder else {
            return "/sdcard/Download/PhoneBridge"
        }
        return remotePathsByDeviceID[deviceID] ?? "/sdcard/Download/PhoneBridge"
    }

    private func normalizedAndroidDirectory(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"),
              !trimmed.contains("\n"),
              !trimmed.contains("\r") else { return nil }
        if trimmed == "/" { return trimmed }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .isEmpty
            ? "/"
            : "/" + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func makeAndroidDestinationSelector(deviceID: String) -> (container: NSView, comboBox: NSComboBox) {
        let current = currentAndroidUploadDirectory(deviceID: deviceID)
        var presets = [
            current,
            "/sdcard/Download/PhoneBridge",
            "/sdcard/Download",
            "/sdcard/DCIM",
            "/sdcard/Pictures",
            "/sdcard/Movies",
            "/sdcard/Documents"
        ]
        presets = presets.reduce(into: []) { result, path in
            if !result.contains(path) { result.append(path) }
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 58))
        let label = NSTextField(labelWithString: "手机目标文件夹（可选择或输入完整路径）")
        let comboBox = NSComboBox(frame: .zero)
        comboBox.addItems(withObjectValues: presets)
        comboBox.stringValue = current
        comboBox.isEditable = true
        comboBox.numberOfVisibleItems = min(7, presets.count)
        label.translatesAutoresizingMaskIntoConstraints = false
        comboBox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        container.addSubview(comboBox)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            comboBox.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            comboBox.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            comboBox.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            comboBox.heightAnchor.constraint(equalToConstant: 26)
        ])
        return (container, comboBox)
    }

    private func uniqueLocalCopyDestination(
        for source: URL,
        in directory: URL,
        isDirectory: Bool
    ) -> URL {
        let original = directory.appendingPathComponent(source.lastPathComponent, isDirectory: isDirectory)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }

        let extensionName = isDirectory ? "" : source.pathExtension
        let stem = extensionName.isEmpty
            ? source.lastPathComponent
            : source.deletingPathExtension().lastPathComponent
        for index in 1...9_999 {
            let suffix = index == 1 ? " 副本" : " 副本 \(index)"
            let filename = extensionName.isEmpty
                ? "\(stem)\(suffix)"
                : "\(stem)\(suffix).\(extensionName)"
            let candidate = directory.appendingPathComponent(filename, isDirectory: isDirectory)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
    }

    private func uniqueSuggestedName(base: String) -> String {
        let original = localPath.appendingPathComponent(base)
        guard FileManager.default.fileExists(atPath: original.path) else { return base }
        let extensionName = (base as NSString).pathExtension
        let stem = (base as NSString).deletingPathExtension
        for index in 2...9_999 {
            let name = extensionName.isEmpty
                ? "\(stem) \(index)"
                : "\(stem) \(index).\(extensionName)"
            if !FileManager.default.fileExists(atPath: localPath.appendingPathComponent(name).path) {
                return name
            }
        }
        return "\(UUID().uuidString)-\(base)"
    }

    private func promptForLocalItemName(
        title: String,
        message: String,
        defaultName: String
    ) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        textField.stringValue = defaultName
        textField.placeholderString = defaultName
        textField.selectText(nil)
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateNewLocalItem(name: String, destination: URL) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else {
            errorMessage = "名称不能为空。"
            return false
        }
        guard !name.contains("/"), !name.contains(":") else {
            errorMessage = "名称不能包含 / 或 : 字符。"
            return false
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            errorMessage = "当前目录已存在“\(name)”。"
            return false
        }
        return true
    }

    private func destinationKey(_ url: URL) -> String {
        url.standardizedFileURL.path.lowercased()
    }

    private func isValidADBEndpoint(_ endpoint: String) -> Bool {
        guard let separator = endpoint.lastIndex(of: ":") else { return false }
        let host = endpoint[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = endpoint[endpoint.index(after: separator)...]
        guard !host.isEmpty, let port = Int(portText), (1...65_535).contains(port) else { return false }
        return true
    }

    private static func normalizedAirPlayName(_ name: String) -> String {
        let collapsed = name
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let source = collapsed.isEmpty ? "PhoneBridge" : collapsed
        var result = ""
        for character in source {
            let candidate = result + String(character)
            guard candidate.utf8.count <= 48 else { break }
            result = candidate
        }
        return result.isEmpty ? "PhoneBridge" : result
    }

    private func show(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = error.localizedDescription
    }
}

private actor AndroidThumbnailLimiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
