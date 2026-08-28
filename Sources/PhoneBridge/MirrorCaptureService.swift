import AppKit
import AVFoundation
import Combine
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum MirrorCaptureSource {
    case embedded(() -> CGImage?)
    case separateWindow(processID: pid_t)
}

@MainActor
final class MirrorCaptureService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var pendingRecordingURL: URL?
    @Published private(set) var pendingRecordingFilename: String?

    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let windowFrameSource = MirrorWindowFrameSource()
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameProvider: (() -> CGImage?)?
    private var recordingTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var temporaryRecordingURL: URL?
    private var outputWidth = 0
    private var outputHeight = 0
    private var lastPresentationTime = CMTime.invalid

    var hasPendingRecording: Bool {
        pendingRecordingURL != nil
    }

    func captureFrame(from source: MirrorCaptureSource) async throws -> CGImage {
        switch source {
        case .embedded(let provider):
            guard let image = provider() else {
                throw PhoneBridgeError.commandFailed("投屏还没有收到画面，请等待手机画面出现后重试。")
            }
            return image

        case .separateWindow(let processID):
            try requireScreenCapturePermission()
            if isRecording, let image = windowFrameSource.latestFrame {
                return image
            }
            try await windowFrameSource.start(processID: processID)
            defer { windowFrameSource.stop() }
            guard let image = windowFrameSource.latestFrame else {
                throw PhoneBridgeError.commandFailed("没有读取到独立投屏窗口画面。")
            }
            return image
        }
    }

    func startRecording(from source: MirrorCaptureSource) async throws {
        guard !isRecording, !isFinishing else { return }
        guard pendingRecordingURL == nil else {
            throw PhoneBridgeError.commandFailed("请先保存上一次录屏，再开始新的录制。")
        }

        let firstFrame: CGImage
        switch source {
        case .embedded(let provider):
            guard let image = provider() else {
                throw PhoneBridgeError.commandFailed("投屏还没有收到画面，请等待手机画面出现后重试。")
            }
            frameProvider = provider
            firstFrame = image

        case .separateWindow(let processID):
            try requireScreenCapturePermission()
            try await windowFrameSource.start(processID: processID)
            guard let image = windowFrameSource.latestFrame else {
                windowFrameSource.stop()
                throw PhoneBridgeError.commandFailed("没有读取到独立投屏窗口画面。")
            }
            frameProvider = { [weak self] in self?.windowFrameSource.latestFrame }
            firstFrame = image
        }

        do {
            try prepareWriter(firstFrame: firstFrame)
        } catch {
            frameProvider = nil
            windowFrameSource.stop()
            throw error
        }

        isRecording = true
        recordingDuration = 0
        recordingStartedAt = Date()
        lastPresentationTime = .invalid
        onStatus?("投屏录制已开始。")

        recordingTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.isRecording {
                autoreleasepool {
                    if let frame = self.frameProvider?() {
                        self.append(frame: frame)
                    }
                }
                if let startedAt = self.recordingStartedAt {
                    self.recordingDuration = Date().timeIntervalSince(startedAt)
                }
                try? await Task.sleep(nanoseconds: 33_333_333)
            }
        }
    }

    @discardableResult
    func stopRecording() async throws -> URL? {
        guard isRecording, !isFinishing else { return pendingRecordingURL }
        isRecording = false
        isFinishing = true
        recordingTask?.cancel()
        recordingTask = nil
        frameProvider = nil
        windowFrameSource.stop()

        guard let writer = assetWriter,
              let input = videoInput,
              let outputURL = temporaryRecordingURL else {
            resetWriter()
            isFinishing = false
            throw PhoneBridgeError.commandFailed("录屏状态异常，无法生成视频文件。")
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }

        defer {
            resetWriter()
            isFinishing = false
        }

        guard writer.status == .completed else {
            let detail = writer.error?.localizedDescription ?? "未知编码错误"
            try? FileManager.default.removeItem(at: outputURL)
            throw PhoneBridgeError.commandFailed("录屏生成失败：\(detail)")
        }

        pendingRecordingURL = outputURL
        pendingRecordingFilename = "PhoneBridge-录屏-\(Self.timestamp()).mp4"
        recordingDuration = 0
        onStatus?("录屏已完成，请选择保存文件夹。")
        return outputURL
    }

    func markPendingRecordingSaved() {
        pendingRecordingURL = nil
        pendingRecordingFilename = nil
    }

    func discardPendingRecording() throws {
        guard let recordingURL = pendingRecordingURL else { return }
        if FileManager.default.fileExists(atPath: recordingURL.path) {
            try FileManager.default.removeItem(at: recordingURL)
        }
        pendingRecordingURL = nil
        pendingRecordingFilename = nil
        onStatus?("已放弃本次录屏。")
    }

    private func prepareWriter(firstFrame: CGImage) throws {
        let size = Self.recordingSize(for: firstFrame)
        outputWidth = size.width
        outputHeight = size.height

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneBridge-recording-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: 8_000_000,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoMaxKeyFrameIntervalKey: 60,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: compression
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw PhoneBridgeError.commandFailed("当前 Mac 无法创建 H.264 录屏编码器。")
        }
        writer.add(input)

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )

        guard writer.startWriting() else {
            let detail = writer.error?.localizedDescription ?? "未知错误"
            throw PhoneBridgeError.commandFailed("无法开始录屏编码：\(detail)")
        }
        writer.startSession(atSourceTime: .zero)
        assetWriter = writer
        videoInput = input
        pixelBufferAdaptor = adaptor
        temporaryRecordingURL = outputURL
    }

    private func append(frame: CGImage) {
        guard let input = videoInput,
              input.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor,
              let startedAt = recordingStartedAt else { return }

        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        let presentationTime = CMTime(seconds: elapsed, preferredTimescale: 600)
        if lastPresentationTime.isValid,
           CMTimeCompare(presentationTime, lastPresentationTime) <= 0 {
            return
        }

        var pixelBuffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                outputWidth,
                outputHeight,
                kCVPixelFormatType_32BGRA,
                attributes as CFDictionary,
                &pixelBuffer
            )
        }
        guard let pixelBuffer else { return }

        let bounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
        let source = CIImage(cgImage: frame)
        let scale = min(
            CGFloat(outputWidth) / source.extent.width,
            CGFloat(outputHeight) / source.extent.height
        )
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translated = scaled.transformed(by: CGAffineTransform(
            translationX: (CGFloat(outputWidth) - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (CGFloat(outputHeight) - scaled.extent.height) / 2 - scaled.extent.minY
        ))
        let background = CIImage(color: .black).cropped(to: bounds)
        let composed = translated.composited(over: background)
        imageContext.render(
            composed,
            to: pixelBuffer,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        if adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            lastPresentationTime = presentationTime
        }
    }

    private func requireScreenCapturePermission() throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw PhoneBridgeError.commandFailed(
                "独立窗口截屏/录屏需要“屏幕录制”权限。请在系统设置中允许 PhoneBridge，完全退出后重新打开。"
            )
        }
    }

    private func resetWriter() {
        assetWriter = nil
        videoInput = nil
        pixelBufferAdaptor = nil
        recordingStartedAt = nil
        temporaryRecordingURL = nil
        outputWidth = 0
        outputHeight = 0
        lastPresentationTime = .invalid
    }

    private static func recordingSize(for image: CGImage) -> (width: Int, height: Int) {
        let longest = max(image.width, image.height)
        let scale = longest > 1_920 ? 1_920.0 / Double(longest) : 1
        let width = max(2, (Int(Double(image.width) * scale) / 2) * 2)
        let height = max(2, (Int(Double(image.height) * scale) / 2) * 2)
        return (width, height)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private final class MirrorWindowFrameSource: NSObject, SCStreamOutput, SCStreamDelegate {
    private let sampleQueue = DispatchQueue(label: "com.personal.phonebridge.mirror-window-capture")
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private let frameLock = NSLock()
    private var storedFrame: CGImage?
    private var stream: SCStream?

    var latestFrame: CGImage? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return storedFrame
    }

    func start(processID: pid_t) async throws {
        stop()
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == processID
                && $0.frame.width >= 100
                && $0.frame.height >= 100
        }
        guard let window = candidates.max(by: {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }) else {
            throw PhoneBridgeError.commandFailed("没有找到独立投屏窗口，请先让手机画面显示出来。")
        }

        let configuration = SCStreamConfiguration()
        let sourceWidth = max(2, Int(window.frame.width * 2))
        let sourceHeight = max(2, Int(window.frame.height * 2))
        let longest = max(sourceWidth, sourceHeight)
        let scale = longest > 1_920 ? 1_920.0 / Double(longest) : 1
        configuration.width = max(2, (Int(Double(sourceWidth) * scale) / 2) * 2)
        configuration.height = max(2, (Int(Double(sourceHeight) * scale) / 2) * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.scalesToFit = true

        let newStream = SCStream(
            filter: SCContentFilter(desktopIndependentWindow: window),
            configuration: configuration,
            delegate: self
        )
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        stream = newStream
        do {
            try await newStream.startCapture()
        } catch {
            if stream === newStream { stream = nil }
            throw error
        }

        for _ in 0..<50 {
            guard stream === newStream else {
                throw PhoneBridgeError.commandFailed("独立投屏画面采集已停止。")
            }
            if latestFrame != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        stop()
        throw PhoneBridgeError.commandFailed("独立投屏窗口暂时没有画面，请确认屏幕录制权限并重试。")
    }

    func stop() {
        let activeStream = stream
        stream = nil
        if let activeStream {
            activeStream.stopCapture { _ in }
        }
        frameLock.lock()
        storedFrame = nil
        frameLock.unlock()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              self.stream === stream,
              sampleBuffer.isValid,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let frame = imageContext.createCGImage(image, from: image.extent) else { return }
            frameLock.lock()
            storedFrame = frame
            frameLock.unlock()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard self.stream === stream else { return }
        self.stream = nil
    }
}
