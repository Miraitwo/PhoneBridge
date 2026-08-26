import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class AndroidADBService {
    private(set) var adbURL: URL?

    init() {
        adbURL = Self.findADB()
    }

    func refreshADBLocation() {
        adbURL = Self.findADB()
    }

    func pair(endpoint: String, code: String) async throws -> String {
        guard let adbURL else { throw PhoneBridgeError.adbNotFound }
        let result = try await ProcessRunner.run(
            executable: adbURL,
            arguments: ["pair", endpoint, code]
        )
        guard result.exitCode == 0 else {
            throw PhoneBridgeError.commandFailed(Self.bestError(from: result))
        }
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "无线配对成功。" : output
    }

    func connect(endpoint: String) async throws -> String {
        guard let adbURL else { throw PhoneBridgeError.adbNotFound }
        let result = try await ProcessRunner.run(
            executable: adbURL,
            arguments: ["connect", endpoint]
        )
        guard result.exitCode == 0 else {
            throw PhoneBridgeError.commandFailed(Self.bestError(from: result))
        }
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "已连接无线 Android。" : output
    }

    func disconnect(endpoint: String) async throws -> String {
        guard let adbURL else { throw PhoneBridgeError.adbNotFound }
        let arguments = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ["disconnect"]
            : ["disconnect", endpoint]
        let result = try await ProcessRunner.run(executable: adbURL, arguments: arguments)
        guard result.exitCode == 0 else {
            throw PhoneBridgeError.commandFailed(Self.bestError(from: result))
        }
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "已断开无线 Android。" : output
    }

    func openPhoneBridgePage(deviceID: String, networkURL: URL) async throws -> URL {
        guard let adbURL else { throw PhoneBridgeError.adbNotFound }
        var candidates: [URL] = []

        if let port = networkURL.port,
           var loopbackComponents = URLComponents(url: networkURL, resolvingAgainstBaseURL: false) {
            let portText = "tcp:\(port)"
            let reverse = try await ProcessRunner.run(
                executable: adbURL,
                arguments: ["-s", deviceID, "reverse", portText, portText]
            )
            if reverse.exitCode == 0 {
                loopbackComponents.host = "127.0.0.1"
                if let loopbackURL = loopbackComponents.url {
                    candidates.append(loopbackURL)
                }
            }
        }
        candidates.append(networkURL)

        var lastError = "Android 无法打开文本页面。"
        for candidate in candidates {
            let result = try await ProcessRunner.run(
                executable: adbURL,
                arguments: [
                    "-s", deviceID, "shell", "am", "start",
                    "-a", "android.intent.action.VIEW",
                    "-d", candidate.absoluteString
                ]
            )
            if result.exitCode == 0 { return candidate }
            lastError = Self.bestError(from: result)
        }
        throw PhoneBridgeError.commandFailed(lastError)
    }

    func removeReverse(deviceID: String, port: Int) async {
        guard let adbURL else { return }
        _ = try? await ProcessRunner.run(
            executable: adbURL,
            arguments: ["-s", deviceID, "reverse", "--remove", "tcp:\(port)"]
        )
    }

    func devices() async throws -> [PhoneDevice] {
        guard let adbURL else { throw PhoneBridgeError.adbNotFound }
        let result = try await ProcessRunner.run(executable: adbURL, arguments: ["devices", "-l"])
        guard result.exitCode == 0 else {
            throw PhoneBridgeError.commandFailed(Self.bestError(from: result))
        }
        return Self.parseDevices(result.standardOutput)
    }

    func entries(deviceID: String, at remotePath: String) async throws -> [RemoteEntry] {
        guard let adbURL else { throw PhoneBridgeError.adbNotFound }
        let quotedPath = Self.shellQuote(remotePath)
        let script = "base=\(quotedPath); for f in \"$base\"/* \"$base\"/.[!.]* \"$base\"/..?*; do [ -e \"$f\" ] || continue; stat -c '%F|%s|%Y|%n' \"$f\" 2>/dev/null; done"
        let result = try await ProcessRunner.run(
            executable: adbURL,
            arguments: ["-s", deviceID, "shell", script]
        )
        guard result.exitCode == 0 else {
            throw PhoneBridgeError.commandFailed(Self.bestError(from: result))
        }
        return Self.parseDirectoryListing(result.standardOutput, deviceID: deviceID)
    }

    func mediaEntries(deviceID: String, kind: RemoteEntryKind) async throws -> [RemoteEntry] {
        guard kind == .image || kind == .video else { return [] }
        guard let adbURL else { throw PhoneBridgeError.adbNotFound }
        let roots = [
            "/sdcard/DCIM",
            "/sdcard/Pictures",
            "/sdcard/Movies",
            "/sdcard/Download"
        ]
        let rootArguments = roots.map(Self.shellQuote).joined(separator: " ")
        let extensions = kind == .image ? Self.imageExtensions : Self.videoExtensions
        let extensionPredicate = extensions.sorted()
            .map { "-iname \(Self.shellQuote("*.\($0)"))" }
            .joined(separator: " -o ")
        let script = "find \(rootArguments) \\( -type d \\( -name '.*' -o -name '*.apk' \\) -prune \\) -o \\( -type f \\( \(extensionPredicate) \\) -print0 \\) 2>/dev/null | xargs -0 stat -c '%F|%s|%Y|%n' 2>/dev/null | head -n 3000"
        let result = try await ProcessRunner.run(
            executable: adbURL,
            arguments: ["-s", deviceID, "shell", script]
        )
        guard result.exitCode == 0 else {
            throw PhoneBridgeError.commandFailed(Self.bestError(from: result))
        }

        var seenPaths = Set<String>()
        return Self.parseDirectoryListing(result.standardOutput, deviceID: deviceID)
            .filter { !$0.isDirectory && $0.kind == kind && seenPaths.insert($0.remotePath).inserted }
    }

    func thumbnailData(for entry: RemoteEntry, maximumPixelSize: Int = 240) async throws -> Data? {
        guard entry.platform == .android, !entry.isDirectory else { return nil }
        guard let adbURL else { throw PhoneBridgeError.adbNotFound }
        if entry.kind == .video, entry.size > 1_000_000_000 {
            throw PhoneBridgeError.commandFailed("视频超过 1GB，已跳过缩略图以避免长时间下载。")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneBridgeAndroidThumbnails", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceURL = directory.appendingPathComponent(entry.name)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await ProcessRunner.run(
            executable: adbURL,
            arguments: ["-s", entry.deviceID, "pull", entry.remotePath, sourceURL.path]
        )
        guard result.exitCode == 0 else {
            throw PhoneBridgeError.commandFailed(Self.bestError(from: result))
        }

        return try await Task.detached(priority: .utility) {
            try Self.makeThumbnailData(
                sourceURL: sourceURL,
                kind: entry.kind,
                maximumPixelSize: maximumPixelSize
            )
        }.value
    }

    func pull(
        deviceID: String,
        remotePath: String,
        destination: URL,
        expectedSize: Int64,
        onProgress: @escaping (Double) -> Void
    ) async throws {
        guard let adbURL else { throw PhoneBridgeError.adbNotFound }
        let pullTask = Task {
            try await ProcessRunner.run(
                executable: adbURL,
                arguments: ["-s", deviceID, "pull", remotePath, destination.path]
            )
        }
        let progressTask = Task {
            while !Task.isCancelled {
                if expectedSize > 0,
                   let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
                   let currentSize = attributes[.size] as? NSNumber {
                    let fraction = min(0.98, currentSize.doubleValue / Double(expectedSize))
                    onProgress(fraction)
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }

        do {
            let result = try await pullTask.value
            progressTask.cancel()
            guard result.exitCode == 0 else {
                try? FileManager.default.removeItem(at: destination)
                throw PhoneBridgeError.commandFailed(Self.bestError(from: result))
            }
            onProgress(1)
        } catch {
            progressTask.cancel()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func push(
        deviceID: String,
        source: URL,
        remoteDirectory: String = "/sdcard/Download/PhoneBridge",
        onProgress: @escaping (Double) -> Void
    ) async throws {
        guard let adbURL else { throw PhoneBridgeError.adbNotFound }
        let mkdir = try await ProcessRunner.run(
            executable: adbURL,
            arguments: ["-s", deviceID, "shell", "mkdir -p \(Self.shellQuote(remoteDirectory))"]
        )
        guard mkdir.exitCode == 0 else {
            throw PhoneBridgeError.commandFailed(Self.bestError(from: mkdir))
        }

        let remotePath = remoteDirectory + "/" + source.lastPathComponent
        let expectedSize = ((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)) ?? 0
        let pushTask = Task {
            try await ProcessRunner.run(
                executable: adbURL,
                arguments: ["-s", deviceID, "push", source.path, remotePath]
            )
        }
        let progressTask = Task {
            while !Task.isCancelled {
                if expectedSize > 0 {
                    let result = try? await ProcessRunner.run(
                        executable: adbURL,
                        arguments: ["-s", deviceID, "shell", "stat -c %s \(Self.shellQuote(remotePath)) 2>/dev/null || echo 0"]
                    )
                    if let output = result?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines),
                       let currentSize = Int64(output.split(whereSeparator: \Character.isNewline).last ?? "0") {
                        onProgress(min(0.98, Double(currentSize) / Double(expectedSize)))
                    }
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        do {
            let result = try await pushTask.value
            progressTask.cancel()
            guard result.exitCode == 0 else {
                throw PhoneBridgeError.commandFailed(Self.bestError(from: result))
            }
            onProgress(1)
        } catch {
            progressTask.cancel()
            throw error
        }
    }

    static func parseDevices(_ output: String) -> [PhoneDevice] {
        output
            .split(whereSeparator: \Character.isNewline)
            .dropFirst()
            .compactMap { rawLine in
                let columns = rawLine.split(whereSeparator: \Character.isWhitespace).map(String.init)
                guard columns.count >= 2, columns[1] == "device" else { return nil }
                let serial = columns[0]
                let attributes = Dictionary(uniqueKeysWithValues: columns.dropFirst(2).compactMap { part -> (String, String)? in
                    let pieces = part.split(separator: ":", maxSplits: 1).map(String.init)
                    guard pieces.count == 2 else { return nil }
                    return (pieces[0], pieces[1])
                })
                let model = attributes["model"]?.replacingOccurrences(of: "_", with: " ") ?? "Android 手机"
                let product = attributes["product"] ?? serial
                return PhoneDevice(id: serial, name: model, platform: .android, detail: product)
            }
    }

    static func parseDirectoryListing(_ output: String, deviceID: String) -> [RemoteEntry] {
        output
            .split(whereSeparator: \Character.isNewline)
            .compactMap { rawLine -> RemoteEntry? in
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 4 else { return nil }

                let type = fields[0].lowercased()
                let path = fields[3]
                let name = (path as NSString).lastPathComponent
                let size = Int64(fields[1]) ?? 0
                let date = TimeInterval(fields[2]).map(Date.init(timeIntervalSince1970:))

                let kind: RemoteEntryKind
                if type.contains("directory") {
                    kind = .directory
                } else if Self.imageExtensions.contains((name as NSString).pathExtension.lowercased()) {
                    kind = .image
                } else if Self.videoExtensions.contains((name as NSString).pathExtension.lowercased()) {
                    kind = .video
                } else {
                    return nil
                }

                return RemoteEntry(
                    id: "android|\(deviceID)|\(path)",
                    deviceID: deviceID,
                    platform: .android,
                    name: name,
                    remotePath: path,
                    kind: kind,
                    size: size,
                    modifiedAt: date
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "webp", "dng", "raw"
    ]

    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "3gp", "avi", "mkv", "webm"
    ]

    private static func makeThumbnailData(
        sourceURL: URL,
        kind: RemoteEntryKind,
        maximumPixelSize: Int
    ) throws -> Data? {
        let image: CGImage?
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return nil }
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
            ] as CFDictionary)
        case .video:
            let asset = AVURLAsset(url: sourceURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
            image = try generator.copyCGImage(
                at: CMTime(seconds: 0.2, preferredTimescale: 600),
                actualTime: nil
            )
        case .directory:
            return nil
        }

        guard let image else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.84
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func findADB() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates: [String] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("adb").path)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            home.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path,
            "/Library/Android/sdk/platform-tools/adb"
        ])
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func bestError(from result: CommandResult) -> String {
        let message = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return message }
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "ADB 命令执行失败（退出码 \(result.exitCode)）。" : output
    }
}
