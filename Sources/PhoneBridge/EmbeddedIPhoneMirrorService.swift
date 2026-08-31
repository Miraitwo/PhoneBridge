import AppKit
import Combine
import Foundation
import ImageIO
import Network

enum EmbeddedMirrorState: Equatable {
    case idle
    case startingAirPlayReceiver
    case startingEmbeddedReceiver
    case waitingForIPhone
    case running
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isActive: Bool {
        switch self {
        case .idle, .failed:
            return false
        default:
            return true
        }
    }

    var message: String {
        switch self {
        case .idle:
            return "点击“启动 AirPlay”，再从 iPhone 控制中心选择界面显示的接收名称。"
        case .startingAirPlayReceiver:
            return "正在启动 PhoneBridge AirPlay 接收器…"
        case .startingEmbeddedReceiver:
            return "正在准备投屏画面通道…"
        case .waitingForIPhone:
            return "接收器已启动。请在 iPhone 控制中心 → 屏幕镜像中选择界面显示的接收名称。"
        case .running:
            return "iPhone 投屏画面已连接。"
        case .failed(let message):
            return message
        }
    }
}

struct JPEGStreamParser {
    private static let jpegStart = Data([0xff, 0xd8])
    private static let jpegEnd = Data([0xff, 0xd9])
    private static let maximumBufferedBytes = 20 * 1_024 * 1_024

    private var buffer = Data()

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func append(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)

        var frames: [Data] = []
        while true {
            guard let startRange = buffer.range(of: Self.jpegStart) else {
                if buffer.count > 1 {
                    buffer = Data(buffer.suffix(1))
                }
                return frames
            }

            if startRange.lowerBound > buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<startRange.lowerBound)
            }

            let searchStart = buffer.index(buffer.startIndex, offsetBy: 2)
            guard let endRange = buffer.range(
                of: Self.jpegEnd,
                in: searchStart..<buffer.endIndex
            ) else {
                if buffer.count > Self.maximumBufferedBytes {
                    buffer.removeAll(keepingCapacity: true)
                }
                return frames
            }

            frames.append(buffer.subdata(in: buffer.startIndex..<endRange.upperBound))
            buffer.removeSubrange(buffer.startIndex..<endRange.upperBound)
        }
    }
}

final class EmbeddedIPhoneMirrorService: ObservableObject {
    @Published private(set) var state: EmbeddedMirrorState = .idle
    @Published private(set) var latestFrame: CGImage?
    @Published private(set) var framePixelSize: CGSize?
    @Published private(set) var framesPerSecond: Double = 0

    var onStatus: ((String) -> Void)?
    var onStreamEnded: (() -> Void)?

    private let frameQueue = DispatchQueue(label: "com.personal.phonebridge.airplay-frames")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var frameParser = JPEGStreamParser()
    private var receiverGeneration = UUID()
    private(set) var streamPort: UInt16?
    private var frameMeasurementStartedAt = Date()
    private var measuredFrameCount = 0
    private var currentConnectionReceivedFrame = false

    func markStartingAirPlayReceiver() {
        state = .startingAirPlayReceiver
        onStatus?(state.message)
    }

    @discardableResult
    func startFrameReceiver(port requestedPort: UInt16? = nil) -> UInt16? {
        stopReceiver(clearPort: false)

        let portNumber = requestedPort ?? UInt16.random(in: 50_000...59_000)
        guard let port = NWEndpoint.Port(rawValue: portNumber) else {
            reportFailure("无法创建投屏画面端口。")
            return nil
        }

        let newListener: NWListener
        do {
            newListener = try NWListener(using: .tcp, on: port)
        } catch {
            reportFailure("无法启动投屏画面通道：\(error.localizedDescription)")
            return nil
        }

        let generation = UUID()
        receiverGeneration = generation
        frameParser.reset()
        latestFrame = nil
        framePixelSize = nil
        framesPerSecond = 0
        frameMeasurementStartedAt = Date()
        measuredFrameCount = 0
        state = .startingEmbeddedReceiver
        onStatus?(state.message)

        newListener.stateUpdateHandler = { [weak self, weak newListener] listenerState in
            guard let self, let newListener else { return }
            switch listenerState {
            case .ready:
                DispatchQueue.main.async {
                    guard self.receiverGeneration == generation,
                          self.listener === newListener,
                          !self.state.isRunning else { return }
                    self.state = .waitingForIPhone
                    self.onStatus?(self.state.message)
                }
            case .failed(let error):
                DispatchQueue.main.async {
                    guard self.receiverGeneration == generation,
                          self.listener === newListener else { return }
                    self.releaseReceiverResources()
                    self.reportFailure("投屏画面通道已断开：\(error.localizedDescription)")
                }
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self, weak newListener] newConnection in
            guard let self,
                  let newListener,
                  self.receiverGeneration == generation,
                  self.listener === newListener else {
                newConnection.cancel()
                return
            }

            self.connection?.cancel()
            self.connection = newConnection
            self.currentConnectionReceivedFrame = false
            newConnection.start(queue: self.frameQueue)
            self.receiveNextChunk(from: newConnection, generation: generation)
        }

        listener = newListener
        streamPort = portNumber
        newListener.start(queue: frameQueue)
        return portNumber
    }

    func stop() {
        stopReceiver(clearPort: true)
        latestFrame = nil
        framePixelSize = nil
        framesPerSecond = 0
        state = .idle
    }

    private func receiveNextChunk(from activeConnection: NWConnection, generation: UUID) {
        activeConnection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 1_048_576
        ) { [weak self] data, _, isComplete, error in
            guard let self,
                  self.receiverGeneration == generation,
                  self.connection === activeConnection else { return }

            if let data, !data.isEmpty {
                self.consumeVideoData(data, generation: generation)
            }

            if isComplete || error != nil {
                let endedAfterReceivingFrames = self.currentConnectionReceivedFrame
                self.currentConnectionReceivedFrame = false
                activeConnection.cancel()
                if self.connection === activeConnection {
                    self.connection = nil
                }
                DispatchQueue.main.async {
                    guard self.receiverGeneration == generation,
                          self.listener != nil else { return }
                    self.latestFrame = nil
                    self.framePixelSize = nil
                    self.framesPerSecond = 0
                    if endedAfterReceivingFrames {
                        self.onStatus?("iPhone 已断开投屏，正在关闭接收器…")
                        self.onStreamEnded?()
                    } else {
                        self.state = .waitingForIPhone
                        self.onStatus?(self.state.message)
                    }
                }
                return
            }

            self.receiveNextChunk(from: activeConnection, generation: generation)
        }
    }

    private func consumeVideoData(_ data: Data, generation: UUID) {
        let jpegFrames = frameParser.append(data)
        for jpegData in jpegFrames {
            guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            currentConnectionReceivedFrame = true

            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.receiverGeneration == generation,
                      self.listener != nil else { return }
                self.latestFrame = image
                self.framePixelSize = CGSize(width: image.width, height: image.height)
                self.measuredFrameCount += 1
                let elapsed = Date().timeIntervalSince(self.frameMeasurementStartedAt)
                if elapsed >= 1 {
                    self.framesPerSecond = Double(self.measuredFrameCount) / elapsed
                    self.measuredFrameCount = 0
                    self.frameMeasurementStartedAt = Date()
                }
                if self.state != .running {
                    self.state = .running
                    self.onStatus?(self.state.message)
                }
            }
        }
    }

    private func stopReceiver(clearPort: Bool) {
        receiverGeneration = UUID()
        currentConnectionReceivedFrame = false
        releaseReceiverResources()
        frameParser.reset()
        if clearPort {
            streamPort = nil
        }
    }

    private func releaseReceiverResources() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
    }

    private func reportFailure(_ message: String) {
        state = .failed(message)
        onStatus?(message)
    }
}
