import AppKit
import Darwin
import Foundation

struct AndroidMirrorLaunch {
    let processID: pid_t
    let windowTitle: String
}

enum MirroringProcessLifecycle {
    static let uxPlayStreamEndedMarkers = [
        "video_reset: type = RTP_Shutdown",
        "This packet indicates video stream is stopping",
        "raop_rtp_mirror tcp socket was closed by client",
        "on_video_stop"
    ]

    static func uxPlayOutputIndicatesStreamEnded(_ lines: [String]) -> Bool {
        lines.contains { line in
            uxPlayStreamEndedMarkers.contains { line.localizedCaseInsensitiveContains($0) }
        }
    }

    static func processIDs(inPSOutput output: String, executablePath: String) -> [pid_t] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.firstIndex(where: \.isWhitespace),
                  let processID = pid_t(line[..<separator]) else { return nil }
            let command = line[separator...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard command == executablePath || command.hasPrefix(executablePath + " ") else { return nil }
            return processID
        }
    }
}

@MainActor
final class ScreenMirroringService {
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onAndroidStopped: ((String, Bool) -> Void)?
    var onIPhoneStopped: ((String, Bool) -> Void)?

    private var scrcpyProcesses: [String: Process] = [:]
    private var stoppingAndroidDeviceIDs = Set<String>()
    private struct IPhoneMirrorProcess {
        let process: Process
        let outputPipe: Pipe
        var logTail: [String]
        let receiverName: String
        let mode: IPhoneMirrorMode
    }

    private var iPhoneProcesses: [String: IPhoneMirrorProcess] = [:]
    private var stoppingIPhoneSessionIDs = Set<String>()

    init() {
        cleanupOrphanedBundledUxPlayProcesses()
    }

    func iPhoneAirPlayProcessID(sessionID: String) -> pid_t? {
        guard let process = iPhoneProcesses[sessionID]?.process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    func iPhoneAirPlayMode(sessionID: String) -> IPhoneMirrorMode? {
        iPhoneProcesses[sessionID]?.mode
    }

    var activeIPhoneAirPlaySessionIDs: [String] {
        iPhoneProcesses.compactMap { sessionID, session in
            session.process.isRunning ? sessionID : nil
        }
    }

    var hasRunningIPhoneAirPlayReceiver: Bool {
        !activeIPhoneAirPlaySessionIDs.isEmpty
    }

    @discardableResult
    func startAndroid(device: PhoneDevice) -> AndroidMirrorLaunch? {
        if let existing = scrcpyProcesses[device.id], existing.isRunning {
            let title = androidWindowTitle(device: device)
            onStatus?("\(device.name) 的 scrcpy 独立窗口已经打开。")
            return AndroidMirrorLaunch(processID: existing.processIdentifier, windowTitle: title)
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
        let windowTitle = androidWindowTitle(device: device)
        let arguments = [
            "--serial", device.id,
            "--window-title", windowTitle,
            "--stay-awake"
        ]
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
                let wasStoppedByApp = self.stoppingAndroidDeviceIDs.remove(device.id) != nil
                self.onAndroidStopped?(device.id, !wasStoppedByApp)
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
            onStatus?("正在启动 \(device.name) 的 scrcpy 独立窗口…")
            return AndroidMirrorLaunch(
                processID: process.processIdentifier,
                windowTitle: windowTitle
            )
        } catch {
            onError?("无法启动 scrcpy：\(error.localizedDescription)")
            return nil
        }
    }

    func stopAndroid(deviceID: String) {
        guard let process = scrcpyProcesses[deviceID], process.isRunning else {
            scrcpyProcesses.removeValue(forKey: deviceID)
            return
        }
        stoppingAndroidDeviceIDs.insert(deviceID)
        process.interrupt()
    }

    func androidMirrorProcessID(deviceID: String) -> pid_t? {
        guard let process = scrcpyProcesses[deviceID], process.isRunning else { return nil }
        return process.processIdentifier
    }

    private func androidWindowTitle(device: PhoneDevice) -> String {
        "PhoneBridge · \(device.name)"
    }

    @discardableResult
    func startIPhoneAirPlay(
        sessionID: String,
        streamPort: UInt16? = nil,
        quality: IPhoneMirrorQuality,
        receiverName: String,
        mode: IPhoneMirrorMode,
        peerToPeer: Bool = false,
        pin: String? = nil
    ) -> pid_t? {
        if let processID = iPhoneAirPlayProcessID(sessionID: sessionID),
           let receiverName = iPhoneProcesses[sessionID]?.receiverName {
            onStatus?("AirPlay 接收器已经启动。请在 iPhone 的“屏幕镜像”中选择“\(receiverName)”。")
            return processID
        }

        if let activeSessionID = activeIPhoneAirPlaySessionIDs.first,
           activeSessionID != sessionID {
            onError?("已有一个 iPhone AirPlay 接收器正在运行，请等待它停止后再启动。")
            return nil
        }

        if streamPort == nil {
            onError?("投屏画面通道尚未准备好，请重新启动投屏。")
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
        process.executableURL = executable
        var arguments = [
            "-n", normalizedReceiverName,
            "-nh",
            "-m", airPlayDeviceID,
            "-d", "1",
            "-as", "0",
            "-vsync", "no",
            "-s", quality.requestedResolution,
            "-fps", String(quality.maximumFrameRate)
        ]
        if let streamPort {
            // Both display modes use the stable JPEG/TCP path. PhoneBridge
            // renders separate mode in its own native NSWindow; this avoids
            // avsamplebufferlayersink, which crashes inside libgstapplemedia
            // while processing real AirPlay frames on macOS 26.
            arguments.append(contentsOf: [
                "-vs", "jpegenc quality=\(quality.jpegQuality) ! tcpclientsink host=127.0.0.1 port=\(streamPort)"
            ])
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

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.consumeUxPlayOutput(message, sessionID: sessionID)
            }
        }

        process.terminationHandler = { [weak self] finishedProcess in
            Task { @MainActor in
                guard let self,
                      let session = self.iPhoneProcesses[sessionID],
                      session.process === finishedProcess else { return }
                let wasStoppedByUser = self.stoppingIPhoneSessionIDs.remove(sessionID) != nil
                session.outputPipe.fileHandleForReading.readabilityHandler = nil
                let detail = session.logTail.suffix(3).joined(separator: " ")
                self.iPhoneProcesses.removeValue(forKey: sessionID)
                self.onIPhoneStopped?(sessionID, !wasStoppedByUser && finishedProcess.terminationStatus != 0)

                if wasStoppedByUser || finishedProcess.terminationStatus == 0 {
                    self.onStatus?("“\(session.receiverName)”AirPlay 投屏已停止。")
                } else {
                    let suffix = detail.isEmpty ? "" : " \(detail)"
                    self.onError?("“\(session.receiverName)”UxPlay 已退出（退出码 \(finishedProcess.terminationStatus)）。\(suffix)")
                }
            }
        }

        do {
            try process.run()
            iPhoneProcesses[sessionID] = IPhoneMirrorProcess(
                process: process,
                outputPipe: outputPipe,
                logTail: [],
                receiverName: normalizedReceiverName,
                mode: mode
            )
            onStatus?(mode == .embedded
                ? "正在启动“\(normalizedReceiverName)”AirPlay 内嵌接收器…"
                : "正在启动“\(normalizedReceiverName)”AirPlay 独立窗口…")
            return process.processIdentifier
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            onError?("无法启动 UxPlay：\(error.localizedDescription)")
            return nil
        }
    }

    func stopIPhoneAirPlay(sessionID: String) {
        guard let session = iPhoneProcesses[sessionID], session.process.isRunning else {
            iPhoneProcesses.removeValue(forKey: sessionID)
            return
        }
        guard stoppingIPhoneSessionIDs.insert(sessionID).inserted else { return }
        sendSignal(SIGINT, to: session.process)
        onStatus?("正在停止“\(session.receiverName)”AirPlay 投屏…")
        scheduleIPhoneStopEscalation(
            sessionID: sessionID,
            process: session.process,
            receiverName: session.receiverName
        )
    }

    func stopAllIPhoneAirPlay() {
        for sessionID in activeIPhoneAirPlaySessionIDs {
            stopIPhoneAirPlay(sessionID: sessionID)
        }
    }

    /// Called during NSApplication termination. It intentionally blocks for a
    /// short bounded interval so child receivers cannot be adopted by launchd.
    func shutdownSynchronously() {
        let childProcesses = Array(iPhoneProcesses.values.map(\.process))
            + Array(scrcpyProcesses.values)
        for process in childProcesses where process.isRunning {
            sendSignal(SIGINT, to: process)
        }
        waitForProcessesToExit(childProcesses, timeout: 0.35)
        for process in childProcesses where isProcessAlive(process.processIdentifier) {
            sendSignal(SIGTERM, to: process)
        }
        waitForProcessesToExit(childProcesses, timeout: 0.35)
        for process in childProcesses where isProcessAlive(process.processIdentifier) {
            sendSignal(SIGKILL, to: process)
        }
    }

    private func consumeUxPlayOutput(_ output: String, sessionID: String) {
        guard var session = iPhoneProcesses[sessionID] else { return }
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        session.logTail.append(contentsOf: lines)
        if session.logTail.count > 20 {
            session.logTail.removeFirst(session.logTail.count - 20)
        }
        iPhoneProcesses[sessionID] = session

        if lines.contains(where: { $0.contains("Initialized server socket") }) {
            onStatus?("AirPlay 接收器已启动。请在 iPhone 控制中心 → 屏幕镜像中选择“\(session.receiverName)”。")
        }
        if lines.contains(where: { $0.contains("SO_RECV_ANYIF") && $0.localizedCaseInsensitiveContains("failed") }) {
            onError?("附近设备 AirPlay 启动失败。请确认 Mac 的 Wi-Fi、蓝牙和本地网络权限已开启，再重新启动接收器。")
        }
        if MirroringProcessLifecycle.uxPlayOutputIndicatesStreamEnded(lines) {
            onStatus?("iPhone 已断开投屏，正在关闭 AirPlay 接收器…")
            stopIPhoneAirPlay(sessionID: sessionID)
        }
    }

    /// A single stable, locally administered Device ID lets Bonjour replace a
    /// previous advertisement instead of caching one identity per phone.
    private var airPlayDeviceID: String {
        "02:50:42:52:49:44"
    }

    private func scheduleIPhoneStopEscalation(
        sessionID: String,
        process: Process,
        receiverName: String
    ) {
        let processID = process.processIdentifier
        Task { @MainActor [weak self, weak process] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self, let process,
                  self.iPhoneProcesses[sessionID]?.process === process,
                  self.isProcessAlive(processID) else { return }
            self.sendSignal(SIGTERM, to: process)

            try? await Task.sleep(nanoseconds: 500_000_000)
            guard self.iPhoneProcesses[sessionID]?.process === process,
                  self.isProcessAlive(processID) else { return }
            self.sendSignal(SIGKILL, to: process)
            self.onStatus?("“\(receiverName)”未正常退出，已强制关闭 AirPlay 接收器。")
        }
    }

    private func cleanupOrphanedBundledUxPlayProcesses() {
        guard let executablePath = Bundle.main.resourceURL?
            .appendingPathComponent("uxplay").path,
              FileManager.default.isExecutableFile(atPath: executablePath) else { return }

        let ps = Process()
        let outputPipe = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        ps.standardOutput = outputPipe
        ps.standardError = FileHandle.nullDevice
        do {
            try ps.run()
            // Drain stdout before waiting. `ps -axo ...` can exceed the pipe
            // buffer on a busy Mac; waiting first would leave ps blocked on a
            // full pipe and freeze PhoneBridge during AppModel initialization.
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            ps.waitUntilExit()
            let output = String(data: outputData, encoding: .utf8) ?? ""

            let processIDs = MirroringProcessLifecycle.processIDs(
                inPSOutput: output,
                executablePath: executablePath
            )
            for processID in processIDs where processID != getpid() {
                _ = Darwin.kill(processID, SIGTERM)
            }
            waitForProcessIDsToExit(processIDs, timeout: 0.3)
            for processID in processIDs where isProcessAlive(processID) {
                _ = Darwin.kill(processID, SIGKILL)
            }
        } catch {
            return
        }
    }

    private func sendSignal(_ signal: Int32, to process: Process) {
        guard process.processIdentifier > 0, isProcessAlive(process.processIdentifier) else { return }
        _ = Darwin.kill(process.processIdentifier, signal)
    }

    private func isProcessAlive(_ processID: pid_t) -> Bool {
        guard processID > 0 else { return false }
        if Darwin.kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private func waitForProcessesToExit(_ processes: [Process], timeout: TimeInterval) {
        waitForProcessIDsToExit(processes.map(\.processIdentifier), timeout: timeout)
    }

    private func waitForProcessIDsToExit(_ processIDs: [pid_t], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline,
              processIDs.contains(where: isProcessAlive) {
            usleep(25_000)
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
