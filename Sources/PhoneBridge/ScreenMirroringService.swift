import AppKit
import Foundation

struct AndroidMirrorLaunch {
    let processID: pid_t
    let windowTitle: String
    let mode: AndroidMirrorMode
}

@MainActor
final class ScreenMirroringService {
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAndroidStopped: ((String, AndroidMirrorMode, Bool) -> Void)?

    private var scrcpyProcesses: [String: Process] = [:]
    private var scrcpyModes: [String: AndroidMirrorMode] = [:]
    private var stoppingAndroidDeviceIDs = Set<String>()
    private var uxPlayProcess: Process?
    private var uxPlayOutputPipe: Pipe?
    private var uxPlayLogTail: [String] = []
    private var isStoppingUxPlay = false
    private var hasActivatedIPhoneWindow = false
    private var iPhoneAirPlayReceiverName = "PhoneBridge"
    private(set) var iPhoneAirPlayMode: IPhoneMirrorMode?

    var iPhoneAirPlayProcessID: pid_t? {
        guard let uxPlayProcess, uxPlayProcess.isRunning else { return nil }
        return uxPlayProcess.processIdentifier
    }

    @discardableResult
    func startAndroid(device: PhoneDevice, mode: AndroidMirrorMode = .separateWindow) -> AndroidMirrorLaunch? {
        if let existing = scrcpyProcesses[device.id], existing.isRunning,
           scrcpyModes[device.id] == mode {
            let title = androidWindowTitle(device: device, mode: mode)
            onStatus?(mode == .embedded
                ? "\(device.name) 的内嵌投屏已经启动。"
                : "\(device.name) 的 scrcpy 独立窗口已经打开。")
            return AndroidMirrorLaunch(processID: existing.processIdentifier, windowTitle: title, mode: mode)
        }
        if scrcpyProcesses[device.id]?.isRunning == true {
            stopAndroid(deviceID: device.id)
        }

        guard let executable = findScrcpy() else {
            onError?("没有找到 scrcpy。请执行 brew install scrcpy 后重试。")
            return nil
        }

        let process = Process()
        process.executableURL = executable
        let windowTitle = androidWindowTitle(device: device, mode: mode)
        var arguments = [
            "--serial", device.id,
            "--window-title", windowTitle,
            "--stay-awake"
        ]
        if mode == .embedded {
            arguments.append(contentsOf: [
                "--no-audio",
                "--window-borderless",
                "--window-x", "0",
                "--window-y", "0",
                "--window-width", "360",
                "--window-height", "640",
                "--max-size", "1920"
            ])
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        configureBundledRuntimeEnvironment(&environment)
        process.environment = environment
        if let nullOutput = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = nullOutput
            process.standardError = nullOutput
        }
        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor in
                guard let self else { return }
                guard self.scrcpyProcesses[device.id] === finishedProcess else { return }
                self.scrcpyProcesses.removeValue(forKey: device.id)
                let finishedMode = self.scrcpyModes.removeValue(forKey: device.id) ?? mode
                let wasStoppedByApp = self.stoppingAndroidDeviceIDs.remove(device.id) != nil
                self.onAndroidStopped?(device.id, finishedMode, !wasStoppedByApp)
                if !wasStoppedByApp, finishedProcess.terminationStatus != 0 {
                    self.onError?("scrcpy 投屏已结束（退出码 \(finishedProcess.terminationStatus)）。请确认 USB 调试已授权。")
                } else if !wasStoppedByApp {
                    self.onStatus?("Android 投屏窗口已关闭。")
                }
            }
        }

        do {
            try process.run()
            scrcpyProcesses[device.id] = process
            scrcpyModes[device.id] = mode
            onStatus?(mode == .embedded
                ? "正在把 \(device.name) 的 scrcpy 画面接入侧栏…"
                : "正在启动 \(device.name) 的 scrcpy 独立窗口…")
            return AndroidMirrorLaunch(
                processID: process.processIdentifier,
                windowTitle: windowTitle,
                mode: mode
            )
        } catch {
            onError?("无法启动 scrcpy：\(error.localizedDescription)")
            return nil
        }
    }

    func stopAndroid(deviceID: String, onlyIf mode: AndroidMirrorMode? = nil) {
        guard let process = scrcpyProcesses[deviceID], process.isRunning else {
            scrcpyProcesses.removeValue(forKey: deviceID)
            scrcpyModes.removeValue(forKey: deviceID)
            return
        }
        if let mode, scrcpyModes[deviceID] != mode { return }
        stoppingAndroidDeviceIDs.insert(deviceID)
        process.interrupt()
    }

    func androidMirrorMode(deviceID: String) -> AndroidMirrorMode? {
        guard scrcpyProcesses[deviceID]?.isRunning == true else { return nil }
        return scrcpyModes[deviceID]
    }

    func androidMirrorProcessID(deviceID: String) -> pid_t? {
        guard let process = scrcpyProcesses[deviceID], process.isRunning else { return nil }
        return process.processIdentifier
    }

    private func androidWindowTitle(device: PhoneDevice, mode: AndroidMirrorMode) -> String {
        switch mode {
        case .embedded: return "PhoneBridge Embedded · \(device.id)"
        case .separateWindow: return "PhoneBridge · \(device.name)"
        }
    }

    @discardableResult
    func startIPhoneAirPlay(
        streamPort: UInt16? = nil,
        quality: IPhoneMirrorQuality,
        receiverName: String,
        mode: IPhoneMirrorMode,
        peerToPeer: Bool = false,
        pin: String? = nil
    ) -> pid_t? {
        if let processID = iPhoneAirPlayProcessID {
            onStatus?("AirPlay 接收器已经启动。请在 iPhone 的“屏幕镜像”中选择“\(iPhoneAirPlayReceiverName)”。")
            return processID
        }

        if mode == .embedded, streamPort == nil {
            onError?("内嵌投屏通道尚未准备好，请重新启动投屏。")
            return nil
        }

        guard let executable = findUxPlay() else {
            onError?("没有找到 UxPlay，无法启动 AirPlay 投屏。")
            return nil
        }

        let process = Process()
        let outputPipe = Pipe()
        let normalizedReceiverName = receiverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "PhoneBridge"
            : receiverName
        iPhoneAirPlayReceiverName = normalizedReceiverName
        iPhoneAirPlayMode = mode
        process.executableURL = executable
        var arguments = [
            "-n", normalizedReceiverName,
            "-nh",
            "-as", "0",
            "-vsync", "no",
            "-s", quality.requestedResolution,
            "-fps", String(quality.maximumFrameRate)
        ]
        if let streamPort, mode == .embedded {
            arguments.append(contentsOf: [
                "-vs", "jpegenc quality=\(quality.jpegQuality) ! tcpclientsink host=127.0.0.1 port=\(streamPort)"
            ])
        } else if mode == .separateWindow {
            // The macOS AVSampleBuffer sink is intentionally registered with
            // rank "none", so UxPlay's default autovideosink cannot discover
            // it reliably in the self-contained app runtime. Select it
            // explicitly so an AirPlay connection always creates a window.
            arguments.append(contentsOf: ["-vs", "avsamplebufferlayersink"])
        }
        if peerToPeer {
            arguments.append("-p2p")
            arguments.append("-pin")
            if let pin, pin.count == 4 {
                arguments.append(pin)
            }
        }
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        configureBundledRuntimeEnvironment(&environment)
        process.environment = environment
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        uxPlayLogTail = []
        isStoppingUxPlay = false
        hasActivatedIPhoneWindow = false
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.consumeUxPlayOutput(message)
            }
        }

        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor in
                guard let self, self.uxPlayProcess === finishedProcess else { return }
                let wasStoppedByUser = self.isStoppingUxPlay
                self.uxPlayOutputPipe?.fileHandleForReading.readabilityHandler = nil
                self.uxPlayOutputPipe = nil
                self.uxPlayProcess = nil
                self.iPhoneAirPlayMode = nil
                self.isStoppingUxPlay = false
                self.hasActivatedIPhoneWindow = false

                if wasStoppedByUser || finishedProcess.terminationStatus == 0 {
                    self.onStatus?("AirPlay 投屏已停止。")
                } else {
                    let detail = self.uxPlayLogTail.suffix(3).joined(separator: " ")
                    let suffix = detail.isEmpty ? "" : " \(detail)"
                    self.onError?("UxPlay 已退出（退出码 \(finishedProcess.terminationStatus)）。\(suffix)")
                }
            }
        }

        do {
            try process.run()
            uxPlayProcess = process
            uxPlayOutputPipe = outputPipe
            onStatus?(mode == .embedded
                ? "正在启动“\(normalizedReceiverName)”AirPlay 内嵌接收器…"
                : "正在启动“\(normalizedReceiverName)”AirPlay 独立窗口…")
            return process.processIdentifier
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            iPhoneAirPlayMode = nil
            onError?("无法启动 UxPlay：\(error.localizedDescription)")
            return nil
        }
    }

    func stopIPhoneAirPlay() {
        guard let process = uxPlayProcess, process.isRunning else {
            uxPlayProcess = nil
            iPhoneAirPlayMode = nil
            return
        }
        isStoppingUxPlay = true
        uxPlayOutputPipe?.fileHandleForReading.readabilityHandler = nil
        uxPlayOutputPipe = nil
        uxPlayProcess = nil
        iPhoneAirPlayMode = nil
        hasActivatedIPhoneWindow = false
        process.interrupt()
        onStatus?("正在停止 AirPlay 投屏…")
    }

    private func consumeUxPlayOutput(_ output: String) {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        uxPlayLogTail.append(contentsOf: lines)
        if uxPlayLogTail.count > 20 {
            uxPlayLogTail.removeFirst(uxPlayLogTail.count - 20)
        }

        if lines.contains(where: { $0.contains("Initialized server socket") }) {
            onStatus?("AirPlay 接收器已启动。请在 iPhone 控制中心 → 屏幕镜像中选择“\(iPhoneAirPlayReceiverName)”。")
        }
        if iPhoneAirPlayMode == .separateWindow,
           !hasActivatedIPhoneWindow,
           lines.contains(where: {
               $0.contains("Begin streaming to GStreamer video pipeline")
                   || $0.contains("raop_rtp_mirror starting mirroring")
                   || $0.contains("Initialized GStreamer video renderer")
           }) {
            hasActivatedIPhoneWindow = true
            activateIPhoneMirrorWindow()
        }
        if lines.contains(where: { $0.contains("SO_RECV_ANYIF") && $0.localizedCaseInsensitiveContains("failed") }) {
            onError?("附近设备 AirPlay 启动失败。请确认 Mac 的 Wi-Fi、蓝牙和本地网络权限已开启，再重新启动接收器。")
        }
    }

    private func activateIPhoneMirrorWindow() {
        guard let processID = iPhoneAirPlayProcessID else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard self?.iPhoneAirPlayProcessID == processID else { return }
            if let application = NSRunningApplication(processIdentifier: processID) {
                application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
            self?.onStatus?("iPhone 独立投屏窗口已打开。")
        }
    }

    private func findScrcpy() -> URL? {
        executableURL(named: "scrcpy", additionalCandidates: [
            "/opt/homebrew/bin/scrcpy",
            "/usr/local/bin/scrcpy"
        ])
    }

    private func findUxPlay() -> URL? {
        executableURL(named: "uxplay", additionalCandidates: [
            "/opt/homebrew/bin/uxplay",
            "/usr/local/bin/uxplay"
        ])
    }

    private func configureBundledRuntimeEnvironment(_ environment: inout [String: String]) {
        var executablePaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var fallbackLibraryPaths = ["/opt/homebrew/lib", "/usr/local/lib", "/usr/lib"]

        if let resourceURL = Bundle.main.resourceURL {
            executablePaths.insert(resourceURL.path, at: 0)

            let scrcpyServer = resourceURL.appendingPathComponent("scrcpy-server")
            if FileManager.default.fileExists(atPath: scrcpyServer.path) {
                environment["SCRCPY_SERVER_PATH"] = scrcpyServer.path
            }

            let pluginScanner = resourceURL
                .appendingPathComponent("gstreamer-1.0")
                .appendingPathComponent("gst-plugin-scanner")
            if FileManager.default.isExecutableFile(atPath: pluginScanner.path) {
                environment["GST_PLUGIN_SCANNER"] = pluginScanner.path
                environment["GST_PLUGIN_SCANNER_1_0"] = pluginScanner.path
            }
        }

        if let frameworksURL = Bundle.main.privateFrameworksURL {
            fallbackLibraryPaths.insert(frameworksURL.path, at: 0)
        }

        if let pluginsURL = Bundle.main.resourceURL?
            .appendingPathComponent("gstreamer-1.0")
            .appendingPathComponent("plugins"),
           FileManager.default.fileExists(atPath: pluginsURL.path) {
            environment["GST_PLUGIN_PATH_1_0"] = pluginsURL.path
            environment["GST_PLUGIN_SYSTEM_PATH_1_0"] = pluginsURL.path

            // Do not reuse ~/.cache/gstreamer-1.0. That global registry may have
            // been built by a different Homebrew/runtime version and can make the
            // bundled UxPlay reject its own plugins. A versioned app-only registry
            // is rebuilt automatically after every PhoneBridge runtime upgrade.
            if let cachesURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
                let registryDirectory = cachesURL
                    .appendingPathComponent("com.personal.phonebridge", isDirectory: true)
                    .appendingPathComponent("gstreamer-1.0", isDirectory: true)
                try? FileManager.default.createDirectory(
                    at: registryDirectory,
                    withIntermediateDirectories: true
                )
                let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
                let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
                let registryURL = registryDirectory
                    .appendingPathComponent("registry-\(shortVersion)-\(buildVersion)-arm64.bin")
                environment["GST_REGISTRY_1_0"] = registryURL.path
                environment["GST_REGISTRY_UPDATE"] = "yes"
            }
        }

        environment["PATH"] = executablePaths.joined(separator: ":")
        environment["DYLD_FALLBACK_LIBRARY_PATH"] = fallbackLibraryPaths.joined(separator: ":")
    }

    private func executableURL(named name: String, additionalCandidates: [String]) -> URL? {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(name))
        }
        candidates.append(contentsOf: additionalCandidates.map(URL.init(fileURLWithPath:)))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
