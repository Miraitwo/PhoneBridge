import AppKit
import Combine
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

enum AndroidEmbeddedMirrorState: Equatable {
    case idle
    case waitingForScrcpyWindow
    case capturing
    case failed(String)

    var isActive: Bool {
        switch self {
        case .waitingForScrcpyWindow, .capturing: return true
        case .idle, .failed: return false
        }
    }

    var isCapturing: Bool {
        if case .capturing = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .idle:
            return "选择“内嵌显示”后点击开始，scrcpy 画面会显示在这里。"
        case .waitingForScrcpyWindow:
            return "正在连接 Android，并准备内嵌画面…"
        case .capturing:
            return "Android 画面已内嵌到 PhoneBridge。"
        case .failed(let message):
            return message
        }
    }
}

final class EmbeddedAndroidMirrorService: NSObject, ObservableObject {
    @Published private(set) var state: AndroidEmbeddedMirrorState = .idle
    @Published private(set) var latestFrame: CGImage?
    @Published private(set) var framePixelSize: CGSize?
    @Published private(set) var framesPerSecond: Double = 0

    var onStatus: ((String) -> Void)?

    private let sampleQueue = DispatchQueue(label: "com.personal.phonebridge.android-mirror-frames")
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var stream: SCStream?
    private var captureGeneration = UUID()
    private var measurementStartedAt = Date()
    private var measuredFrames = 0
    private var isStopping = false
    private var targetProcessID: pid_t?
    private var targetWindowTitle = ""
    private var recoveryAttempts = 0
    private var recoveryTask: Task<Void, Never>?

    func hasScreenCapturePermission(requestIfNeeded: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return requestIfNeeded ? CGRequestScreenCaptureAccess() : false
    }

    func start(processID: pid_t, windowTitle: String) {
        stop(clearFrame: true)
        let generation = UUID()
        captureGeneration = generation
        targetProcessID = processID
        targetWindowTitle = windowTitle
        recoveryAttempts = 0
        state = .waitingForScrcpyWindow
        onStatus?(state.message)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let window = try await self.waitForWindow(
                    processID: processID,
                    title: windowTitle,
                    generation: generation
                )
                guard self.captureGeneration == generation else { return }
                try await self.beginCapture(window: window, generation: generation)
            } catch {
                guard self.captureGeneration == generation else { return }
                self.reportFailure(error.localizedDescription)
            }
        }
    }

    func stop(clearFrame: Bool = true) {
        captureGeneration = UUID()
        isStopping = true
        recoveryTask?.cancel()
        recoveryTask = nil
        targetProcessID = nil
        targetWindowTitle = ""
        recoveryAttempts = 0
        let activeStream = stream
        stream = nil
        if let activeStream {
            activeStream.stopCapture { _ in }
        }
        if clearFrame {
            latestFrame = nil
            framePixelSize = nil
            framesPerSecond = 0
        }
        state = .idle
        isStopping = false
    }

    private func waitForWindow(
        processID: pid_t,
        title: String,
        generation: UUID
    ) async throws -> SCWindow {
        for _ in 0..<30 {
            guard captureGeneration == generation else {
                throw PhoneBridgeError.commandFailed("内嵌投屏已取消。")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            if let window = content.windows.first(where: {
                $0.owningApplication?.processID == processID
                    && ($0.title?.contains(title) == true || title.isEmpty)
            }) ?? content.windows.first(where: { $0.owningApplication?.processID == processID }) {
                return window
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw PhoneBridgeError.commandFailed("没有找到 scrcpy 画面窗口。请确认屏幕录制权限已经开启，然后重新启动 PhoneBridge。")
    }

    private func beginCapture(window: SCWindow, generation: UUID) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let sourceWidth = max(360, Int(window.frame.width * 2))
        let sourceHeight = max(640, Int(window.frame.height * 2))
        let longest = max(sourceWidth, sourceHeight)
        let scale = longest > 1_920 ? 1_920.0 / Double(longest) : 1
        configuration.width = Int(Double(sourceWidth) * scale)
        configuration.height = Int(Double(sourceHeight) * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await newStream.startCapture()
        guard captureGeneration == generation else {
            try? await newStream.stopCapture()
            return
        }
        stream = newStream
        measurementStartedAt = Date()
        measuredFrames = 0
        state = .waitingForScrcpyWindow
        onStatus?("Android 画面通道已启动，正在等待第一帧…")
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self,
                  self.captureGeneration == generation,
                  self.latestFrame == nil else { return }
            self.scheduleRecovery(
                reason: "scrcpy 已启动，但暂时没有收到画面",
                generation: generation
            )
        }
    }

    private func scheduleRecovery(reason: String, generation: UUID) {
        guard captureGeneration == generation,
              let processID = targetProcessID,
              recoveryAttempts < 5 else {
            reportFailure("Android 内嵌画面多次恢复失败。请检查连接，或切换到“独立窗口”。")
            return
        }
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        recoveryTask?.cancel()
        let previousStream = stream
        stream = nil
        if let previousStream {
            previousStream.stopCapture { _ in }
        }
        latestFrame = nil
        framePixelSize = nil
        framesPerSecond = 0
        state = .waitingForScrcpyWindow
        onStatus?("\(reason)，正在自动重连画面（\(attempt)/5）…")

        let title = targetWindowTitle
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.captureGeneration == generation else { return }
            do {
                let window = try await self.waitForWindow(
                    processID: processID,
                    title: title,
                    generation: generation
                )
                guard self.captureGeneration == generation else { return }
                try await self.beginCapture(window: window, generation: generation)
            } catch {
                guard self.captureGeneration == generation else { return }
                self.scheduleRecovery(reason: error.localizedDescription, generation: generation)
            }
        }
    }

    private func reportFailure(_ message: String) {
        latestFrame = nil
        framePixelSize = nil
        framesPerSecond = 0
        state = .failed(message)
        onStatus?(message)
    }
}

extension EmbeddedAndroidMirrorService: SCStreamOutput, SCStreamDelegate {
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let frame = imageContext.createCGImage(image, from: image.extent) else { return }
            let size = CGSize(width: frame.width, height: frame.height)
            measuredFrames += 1
            let elapsed = Date().timeIntervalSince(measurementStartedAt)
            let fps: Double?
            if elapsed >= 1 {
                fps = Double(measuredFrames) / elapsed
                measuredFrames = 0
                measurementStartedAt = Date()
            } else {
                fps = nil
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.stream === stream else { return }
                self.latestFrame = frame
                self.framePixelSize = size
                self.recoveryAttempts = 0
                if let fps { self.framesPerSecond = fps }
                if !self.state.isCapturing {
                    self.state = .capturing
                    self.onStatus?(self.state.message)
                }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            if !self.isStopping {
                self.scheduleRecovery(
                    reason: "Android 内嵌画面通道已停止：\(error.localizedDescription)",
                    generation: self.captureGeneration
                )
            }
        }
    }
}
