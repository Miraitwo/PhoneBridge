import Foundation

enum PhonePlatform: String, Codable, Hashable {
    case android
    case ios

    var displayName: String {
        switch self {
        case .android: return "Android"
        case .ios: return "iPhone / iPad"
        }
    }

    var symbolName: String {
        switch self {
        case .android: return "cable.connector"
        case .ios: return "iphone"
        }
    }
}

struct PhoneDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let platform: PhonePlatform
    let detail: String
}

enum IPhoneMirrorQuality: String, CaseIterable, Identifiable {
    case clear
    case smooth
    case economy

    var id: Self { self }

    var label: String {
        switch self {
        case .clear: return "清晰优先"
        case .smooth: return "流畅优先"
        case .economy: return "节省带宽"
        }
    }

    var requestedResolution: String {
        switch self {
        case .clear, .smooth: return "1920x1080@60"
        case .economy: return "1280x720@60"
        }
    }

    var maximumFrameRate: Int {
        switch self {
        case .clear, .economy: return 30
        case .smooth: return 60
        }
    }

    var jpegQuality: Int {
        switch self {
        case .clear: return 97
        case .smooth: return 92
        case .economy: return 86
        }
    }
}

enum IPhoneMirrorMode: String, CaseIterable, Identifiable {
    case embedded
    case separateWindow

    var id: Self { self }

    var label: String {
        switch self {
        case .embedded: return "内嵌显示"
        case .separateWindow: return "独立窗口"
        }
    }
}

enum AndroidMediaScope: String, Hashable {
    case folder
    case images
    case videos

    var displayPath: String? {
        switch self {
        case .folder: return nil
        case .images: return "/媒体库/照片（自动扫描）"
        case .videos: return "/媒体库/视频（自动扫描）"
        }
    }
}

enum RemoteEntryKind: String, Codable, Hashable {
    case directory
    case image
    case video

    var symbolName: String {
        switch self {
        case .directory: return "folder.fill"
        case .image: return "photo"
        case .video: return "film"
        }
    }
}

struct RemoteEntry: Identifiable, Hashable, Codable {
    let id: String
    let deviceID: String
    let platform: PhonePlatform
    let name: String
    let remotePath: String
    let kind: RemoteEntryKind
    let size: Int64
    let modifiedAt: Date?
    /// Stable ordering fallback for devices that omit all usable media dates.
    /// It is never displayed as a made-up date in the UI.
    let dateSortFallback: Int64?

    var isDirectory: Bool { kind == .directory }
}

struct LocalEntry: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
}

enum TransferConflictPolicy {
    case skip
    case rename
    case overwrite
}

enum TransferState: Equatable {
    case queued
    case running
    case completed
    case failed(String)

    var label: String {
        switch self {
        case .queued: return "等待中"
        case .running: return "传输中"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }
}

struct TransferJob: Identifiable {
    let id: UUID
    let sourceName: String
    let destination: URL
    let totalBytes: Int64
    var progress: Double
    var state: TransferState
    var startedAt: Date?
    var estimatedRemaining: TimeInterval?
    var bytesPerSecond: Double?
}

enum PhoneBridgeError: LocalizedError {
    case adbNotFound
    case commandFailed(String)
    case deviceUnavailable
    case remoteItemUnavailable
    case invalidDropData
    case destinationAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .adbNotFound:
            return "没有找到 adb。请执行 brew install android-platform-tools。"
        case .commandFailed(let message):
            return message
        case .deviceUnavailable:
            return "手机已断开，请重新连接后刷新。"
        case .remoteItemUnavailable:
            return "手机中的文件已不可用，请刷新文件列表。"
        case .invalidDropData:
            return "无法识别拖入的手机文件。"
        case .destinationAlreadyExists(let filename):
            return "Mac 中已存在“\(filename)”，传输期间文件发生了变化，请重新选择处理方式。"
        }
    }
}
