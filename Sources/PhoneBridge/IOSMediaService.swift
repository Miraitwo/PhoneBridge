import Foundation
import ImageCaptureCore
import UniformTypeIdentifiers

@MainActor
final class IOSMediaService: NSObject {
    var onChange: (() -> Void)?
    var onStatus: ((String) -> Void)?

    private let browser = ICDeviceBrowser()
    private var cameras: [String: ICCameraDevice] = [:]
    private var deviceOrder: [String] = []
    private var filesByEntryID: [String: ICCameraFile] = [:]
    private var entriesByDeviceID: [String: [RemoteEntry]] = [:]
    private var thumbnailRequests: [ThumbnailRequest] = []
    private var activeThumbnailRequestCount = 0
    private let maximumConcurrentThumbnailRequests = 3

    private struct ThumbnailRequest {
        let file: ICCameraFile
        let maximumPixelSize: Int
        let continuation: CheckedContinuation<Data?, Error>
    }

    override init() {
        super.init()
        browser.delegate = self
        browser.browsedDeviceTypeMask = .camera
    }

    func start() {
        browser.start()
    }

    func stop() {
        browser.stop()
    }

    /// ImageCaptureCore normally reports connected devices after `start()`, but
    /// occasionally misses that first callback after the app is relaunched.
    /// Restarting discovery gives the Refresh button real iPhone semantics.
    func refreshDiscovery() async {
        if !cameras.isEmpty {
            for camera in cameras.values {
                camera.delegate = self
                if camera.hasOpenSession {
                    rebuildEntries(for: camera)
                } else {
                    camera.requestOpenSession(options: nil) { _ in }
                }
            }
            if cameras.values.contains(where: \.isAccessRestrictedAppleDevice) {
                onStatus?("已找到 iPhone，请解锁并信任此 Mac 后再次刷新。")
            } else {
                onStatus?("正在刷新 iPhone 照片与视频…")
            }
            onChange?()
            return
        }

        onStatus?("正在重新扫描 iPhone…")
        browser.stop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        browser.start()

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.cameras.isEmpty else { return }
            self.onStatus?("未发现可访问的 iPhone。请保持手机解锁，确认已信任此 Mac 后再刷新。")
        }
    }

    var devices: [PhoneDevice] {
        deviceOrder.compactMap { id in
            guard let camera = cameras[id] else { return nil }
            return PhoneDevice(
                id: id,
                name: camera.name ?? camera.productKind ?? "iPhone",
                platform: .ios,
                detail: camera.isAccessRestrictedAppleDevice ? "请解锁并信任此 Mac" : "USB · 照片与视频"
            )
        }
    }

    func entries(deviceID: String) -> [RemoteEntry] {
        entriesByDeviceID[deviceID] ?? []
    }

    func thumbnailData(entryID: String, maximumPixelSize: Int = 180) async throws -> Data? {
        guard let file = filesByEntryID[entryID] else {
            throw PhoneBridgeError.remoteItemUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            thumbnailRequests.append(ThumbnailRequest(
                file: file,
                maximumPixelSize: maximumPixelSize,
                continuation: continuation
            ))
            startPendingThumbnailRequests()
        }
    }

    func download(
        entryID: String,
        destinationDirectory: URL,
        filename: String,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        guard let file = filesByEntryID[entryID] else {
            throw PhoneBridgeError.remoteItemUnavailable
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: destinationDirectory,
                .saveAsFilename: filename,
                .overwrite: false,
                .deleteAfterSuccessfulDownload: false,
                .sidecarFiles: false
            ]

            let progress = file.requestDownload(options: options) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    onProgress(1)
                    continuation.resume(returning: ())
                }
            }

            guard let progress else {
                onProgress(0.05)
                return
            }

            Task { @MainActor in
                while !progress.isFinished && !progress.isCancelled {
                    onProgress(max(0.02, min(0.98, progress.fractionCompleted)))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
    }

    private func rebuildEntries(for camera: ICCameraDevice) {
        guard let deviceID = camera.uuidString else { return }
        var nextFiles: [String: ICCameraFile] = [:]
        let nextEntries = (camera.mediaFiles ?? []).compactMap { item -> RemoteEntry? in
            guard let file = item as? ICCameraFile else { return nil }
            let name = file.name ?? file.originalFilename ?? "未命名文件"
            let type = file.uti.flatMap(UTType.init)
            let kind: RemoteEntryKind
            if type?.conforms(to: .image) == true {
                kind = .image
            } else if type?.conforms(to: .movie) == true {
                kind = .video
            } else {
                return nil
            }

            let timestamp = file.fileCreationDate?.timeIntervalSince1970 ?? 0
            let entryID = "ios|\(deviceID)|\(name)|\(file.fileSize)|\(timestamp)"
            nextFiles[entryID] = file
            return RemoteEntry(
                id: entryID,
                deviceID: deviceID,
                platform: .ios,
                name: name,
                remotePath: name,
                kind: kind,
                size: Int64(file.fileSize),
                modifiedAt: file.fileCreationDate
            )
        }
        .sorted {
            ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
        }

        filesByEntryID = filesByEntryID.filter { !$0.key.hasPrefix("ios|\(deviceID)|") }
        filesByEntryID.merge(nextFiles) { _, new in new }
        entriesByDeviceID[deviceID] = nextEntries
        onChange?()
    }

    private func startPendingThumbnailRequests() {
        while activeThumbnailRequestCount < maximumConcurrentThumbnailRequests,
              !thumbnailRequests.isEmpty {
            let request = thumbnailRequests.removeFirst()
            activeThumbnailRequestCount += 1
            let options: [ICCameraItemThumbnailOption: Any] = [
                .imageSourceThumbnailMaxPixelSize: request.maximumPixelSize
            ]

            request.file.requestThumbnailData(options: options) { [weak self] data, error in
                Task { @MainActor in
                    guard let self else {
                        request.continuation.resume(returning: nil)
                        return
                    }
                    self.activeThumbnailRequestCount -= 1
                    if let error {
                        request.continuation.resume(throwing: error)
                    } else if let data {
                        request.continuation.resume(returning: data)
                    } else {
                        request.continuation.resume(returning: nil)
                    }
                    self.startPendingThumbnailRequests()
                }
            }
        }
    }

    private func isAppleMobileDevice(_ device: ICDevice) -> Bool {
        let kind = (device.productKind ?? "").lowercased()
        return kind.contains("iphone") || kind.contains("ipad") || kind.contains("ipod")
    }
}

extension IOSMediaService: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard self.isAppleMobileDevice(device), let camera = device as? ICCameraDevice else { return }
            let id = camera.uuidString ?? UUID().uuidString
            self.cameras[id] = camera
            if !self.deviceOrder.contains(id) {
                self.deviceOrder.append(id)
            }
            camera.delegate = self
            camera.requestOpenSession()
            self.onStatus?(camera.isAccessRestrictedAppleDevice ? "请解锁 iPhone 并点击“信任”。" : "正在读取 \(camera.name ?? "iPhone")…")
            self.onChange?()
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            guard let id = device.uuidString else { return }
            self.cameras.removeValue(forKey: id)
            self.deviceOrder.removeAll { $0 == id }
            self.entriesByDeviceID.removeValue(forKey: id)
            self.filesByEntryID = self.filesByEntryID.filter { !$0.key.hasPrefix("ios|\(id)|") }
            self.onStatus?("iPhone 已断开。")
            self.onChange?()
        }
    }
}

extension IOSMediaService: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Task { @MainActor in
            if let error {
                self.onStatus?("无法打开 iPhone：\(error.localizedDescription)")
            } else if let camera = device as? ICCameraDevice {
                self.rebuildEntries(for: camera)
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in
            guard let id = device.uuidString else { return }
            self.cameras.removeValue(forKey: id)
            self.deviceOrder.removeAll { $0 == id }
            self.entriesByDeviceID.removeValue(forKey: id)
            self.onChange?()
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in self.rebuildEntries(for: camera) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        Task { @MainActor in self.rebuildEntries(for: camera) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        Task { @MainActor in self.rebuildEntries(for: camera) }
    }

    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in
            self.rebuildEntries(for: device)
            self.onStatus?("已读取 \(device.mediaFiles?.count ?? 0) 个媒体项目。")
        }
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in
            guard let camera = device as? ICCameraDevice else { return }
            self.rebuildEntries(for: camera)
            self.onStatus?("iPhone 已解锁，正在读取照片与视频。")
        }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in self.onStatus?("iPhone 已锁定，请解锁后继续。") }
    }
}
