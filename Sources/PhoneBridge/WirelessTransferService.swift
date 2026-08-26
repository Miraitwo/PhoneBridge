import Darwin
import Foundation
import Network

@MainActor
final class WirelessTransferService: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var accessURLs: [URL] = []
    @Published private(set) var receivedFiles: [String] = []
    @Published private(set) var sharedFilename: String?
    @Published private(set) var sharedFilenames: [String] = []
    @Published private(set) var sharedText: String?

    var onStatus: ((String) -> Void)?
    var onFilesReceived: (() -> Void)?

    private let serverQueue = DispatchQueue(label: "com.personal.phonebridge.transfer-server")
    private var listener: NWListener?
    nonisolated(unsafe) private var destinationDirectory: URL?
    nonisolated(unsafe) private var sharedFileURLs: [URL] = []
    nonisolated(unsafe) private var sharedTextValue: String?
    nonisolated(unsafe) private var accessToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    var primaryURL: URL? { accessURLs.first }

    func start(
        destinationDirectory: URL,
        sharedFile: URL? = nil,
        sharedFiles: [URL]? = nil,
        sharedText: String? = nil,
        allowLoopbackFallback: Bool = false
    ) {
        stop()
        self.destinationDirectory = destinationDirectory
        let files = sharedFiles ?? sharedFile.map { [$0] } ?? []
        sharedFileURLs = files
        sharedFilenames = files.map(\.lastPathComponent)
        sharedFilename = sharedFilenames.first
        sharedTextValue = sharedText
        self.sharedText = sharedText
        receivedFiles = []
        accessToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        state = .starting

        do {
            let newListener = try NWListener(using: .tcp)
            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            newListener.stateUpdateHandler = { [weak self, weak newListener] listenerState in
                guard let self, let newListener else { return }
                switch listenerState {
                case .ready:
                    guard let actualPort = newListener.port?.rawValue else {
                        DispatchQueue.main.async {
                            guard self.listener === newListener else { return }
                            self.fail("系统没有为无线传输分配可用端口。")
                        }
                        return
                    }
                    let addresses = Self.localIPv4Addresses()
                    var urls = addresses.compactMap {
                        URL(string: "http://\($0):\(actualPort)/\(self.accessToken)/")
                    }
                    if urls.isEmpty, allowLoopbackFallback,
                       let loopbackURL = URL(string: "http://127.0.0.1:\(actualPort)/\(self.accessToken)/") {
                        urls = [loopbackURL]
                    }
                    DispatchQueue.main.async {
                        guard self.listener === newListener else { return }
                        if urls.isEmpty {
                            self.fail("没有找到可供手机访问的局域网地址。请确认 Mac 已连接 Wi-Fi 或有线网络。")
                        } else {
                            self.accessURLs = urls
                            self.state = .ready
                            self.onStatus?("无线传输页面已启动：\(urls[0].absoluteString)")
                        }
                    }
                case .failed(let error):
                    DispatchQueue.main.async {
                        guard self.listener === newListener else { return }
                        self.fail("无线传输服务启动失败：\(error.localizedDescription)")
                    }
                default:
                    break
                }
            }
            listener = newListener
            newListener.start(queue: serverQueue)
        } catch {
            fail("无线传输服务启动失败：\(error.localizedDescription)")
        }
    }

    func updateSharedFile(_ file: URL?) {
        sharedFileURLs = file.map { [$0] } ?? []
        sharedFilenames = file.map { [$0.lastPathComponent] } ?? []
        sharedFilename = file?.lastPathComponent
    }

    func stop() {
        listener?.cancel()
        listener = nil
        accessURLs = []
        sharedFileURLs = []
        sharedFilename = nil
        sharedFilenames = []
        sharedTextValue = nil
        sharedText = nil
        state = .idle
    }

    private func fail(_ message: String) {
        listener?.cancel()
        listener = nil
        accessURLs = []
        state = .failed(message)
        onStatus?(message)
    }

    nonisolated private func accept(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        receiveHeader(on: connection, buffer: Data())
    }

    nonisolated private func receiveHeader(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var nextBuffer = buffer
            if let data { nextBuffer.append(data) }

            let separator = Data("\r\n\r\n".utf8)
            if let range = nextBuffer.range(of: separator) {
                let headerData = nextBuffer.subdata(in: nextBuffer.startIndex..<range.lowerBound)
                let bodyData = nextBuffer.subdata(in: range.upperBound..<nextBuffer.endIndex)
                self.handleRequest(headerData: headerData, initialBody: bodyData, connection: connection)
                return
            }

            if nextBuffer.count > 65_536 || isComplete || error != nil {
                self.sendText("请求格式无效。", status: "400 Bad Request", connection: connection)
                return
            }
            self.receiveHeader(on: connection, buffer: nextBuffer)
        }
    }

    nonisolated private func handleRequest(headerData: Data, initialBody: Data, connection: NWConnection) {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            sendText("请求格式无效。", status: "400 Bad Request", connection: connection)
            return
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let requestParts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard requestParts.count >= 2 else {
            sendText("请求格式无效。", status: "400 Bad Request", connection: connection)
            return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
            }
        }

        let method = requestParts[0].uppercased()
        let requestTarget = requestParts[1]
        guard let components = URLComponents(string: "http://phonebridge\(requestTarget)") else {
            sendText("请求地址无效。", status: "400 Bad Request", connection: connection)
            return
        }
        let prefix = "/\(accessToken)"
        guard components.path == prefix || components.path.hasPrefix(prefix + "/") else {
            sendText("链接已失效，请重新扫描二维码。", status: "404 Not Found", connection: connection)
            return
        }
        let route = String(components.path.dropFirst(prefix.count))

        switch (method, route) {
        case ("GET", ""), ("GET", "/"):
            sendHTML(transferPage(), connection: connection)
        case ("GET", "/download"):
            sendSharedFile(index: 0, connection: connection)
        case ("GET", let route) where route.hasPrefix("/download/"):
            guard let index = Int(route.dropFirst("/download/".count)) else {
                sendText("下载地址无效。", status: "400 Bad Request", connection: connection)
                return
            }
            sendSharedFile(index: index, connection: connection)
        case ("POST", "/upload"):
            guard let lengthText = headers["content-length"], let length = Int64(lengthText), length >= 0,
                  let encodedName = components.queryItems?.first(where: { $0.name == "name" })?.value,
                  !encodedName.isEmpty else {
                sendText("上传请求缺少文件名或文件大小。", status: "400 Bad Request", connection: connection)
                return
            }
            let startUpload: () -> Void = { [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.receiveUpload(
                    filename: encodedName,
                    contentLength: length,
                    initialBody: initialBody,
                    connection: connection
                )
            }
            if headers["expect"]?.lowercased().contains("100-continue") == true {
                sendContinue(connection: connection, completion: startUpload)
            } else {
                startUpload()
            }
        default:
            sendText("不支持此操作。", status: "404 Not Found", connection: connection)
        }
    }

    nonisolated private func transferPage() -> String {
        let downloadSection: String
        if !sharedFileURLs.isEmpty {
            let links = sharedFileURLs.enumerated().map { index, file in
                let href = index == 0 ? "download" : "download/\(index)"
                return "<a class=\"button\" href=\"\(href)\">下载 \(htmlEscaped(file.lastPathComponent))</a>"
            }.joined(separator: " ")
            downloadSection = """
            <section><h2>从 Mac 下载（\(sharedFileURLs.count) 个文件）</h2><div class="actions">\(links)</div><p>在 iPhone 上下载后，可通过系统分享菜单选择“存储到文件”并指定文件夹。</p></section>
            """
        } else {
            downloadSection = ""
        }

        let sharedTextSection: String
        if let text = sharedTextValue, !text.isEmpty {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let linkButton: String
            if let url = URL(string: trimmed),
               ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
               url.host != nil {
                linkButton = "<a class=\"button secondary\" href=\"\(htmlEscaped(url.absoluteString))\">打开链接</a>"
            } else {
                linkButton = ""
            }
            sharedTextSection = """
            <section><h2>Mac 发来的文本</h2>
            <textarea id="sharedText" readonly>\(htmlEscaped(text))</textarea>
            <div class="actions"><button onclick="copySharedText()">复制文本</button><button class="secondary" onclick="shareSharedText()">分享到备忘录 / 其他 App</button>\(linkButton)</div>
            <p id="textStatus"></p></section>
            """
        } else {
            sharedTextSection = ""
        }

        return """
        <!doctype html><html lang="zh-CN"><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta charset="utf-8"><title>PhoneBridge 无线传输</title><style>
        body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#f6f3ec;color:#17233d;margin:0;padding:28px}
        main{max-width:620px;margin:auto;background:white;border-radius:24px;padding:26px;box-shadow:0 12px 40px #17233d14}
        h1{font-size:28px;margin:0 0 8px}h2{font-size:18px;margin-top:26px}p{color:#5f6878;line-height:1.55}
        input{width:100%;margin:8px 0 14px}textarea{box-sizing:border-box;width:100%;min-height:180px;padding:14px;border:1px solid #d9dee8;border-radius:14px;background:#f8fafc;color:#17233d;font:16px/1.55 -apple-system,BlinkMacSystemFont,sans-serif;resize:vertical}.actions{display:flex;flex-wrap:wrap;gap:10px;margin-top:12px}.button,button{display:inline-block;border:0;border-radius:12px;padding:12px 18px;background:#1454e8;color:white;text-decoration:none;font-size:16px}.secondary{background:#e8eefc;color:#153d92}
        progress{width:100%;height:12px;margin-top:14px}#status{min-height:24px;color:#245c3c}
        </style></head><body><main><h1>PhoneBridge</h1><p>本页面只在当前 PhoneBridge 会话中有效；无线访问时请让手机与 Mac 保持在同一局域网。</p>
        \(downloadSection)
        \(sharedTextSection)
        <section><h2>发送到 Mac</h2><input id="files" type="file" multiple><button onclick="sendFiles()">开始上传</button>
        <progress id="progress" value="0" max="1"></progress><p id="status"></p></section>
        <section><h2>Charles CA</h2><p>如果手机已经把 HTTP 代理指向 Charles，可直接打开：</p><a href="http://chls.pro/ssl">chls.pro/ssl</a></section>
        <script>
        async function sendOne(file,index,total){return new Promise((resolve,reject)=>{const x=new XMLHttpRequest();
        x.open('POST','upload?name='+encodeURIComponent(file.name));x.upload.onprogress=e=>{if(e.lengthComputable)document.querySelector('#progress').value=(index+e.loaded/e.total)/total};
        x.onload=()=>x.status===200?resolve():reject(x.responseText);x.onerror=()=>reject('网络连接失败');x.send(file);});}
        async function sendFiles(){const fs=[...document.querySelector('#files').files],s=document.querySelector('#status');if(!fs.length){s.textContent='请先选择文件';return}
        try{for(let i=0;i<fs.length;i++){s.textContent='正在上传 '+fs[i].name;await sendOne(fs[i],i,fs.length)}s.textContent='已完成 '+fs.length+' 个文件';}catch(e){s.textContent='上传失败：'+e}}
        async function copySharedText(){const t=document.querySelector('#sharedText'),s=document.querySelector('#textStatus');if(!t)return;
        try{if(navigator.clipboard&&window.isSecureContext){await navigator.clipboard.writeText(t.value)}else{t.focus();t.select();if(!document.execCommand('copy'))throw new Error('复制失败')}s.textContent='已复制到手机剪贴板';}catch(e){t.focus();t.select();s.textContent='请长按选中文本后复制';}}
        async function shareSharedText(){const t=document.querySelector('#sharedText'),s=document.querySelector('#textStatus');if(!t)return;
        if(navigator.share){try{await navigator.share({title:'PhoneBridge 文本',text:t.value});s.textContent='已打开系统分享菜单';}catch(e){if(e.name!=='AbortError')s.textContent='分享失败，可先复制文本';}}else{copySharedText();}}
        </script></main></body></html>
        """
    }

    nonisolated private func receiveUpload(
        filename: String,
        contentLength: Int64,
        initialBody: Data,
        connection: NWConnection
    ) {
        guard let destinationDirectory else {
            sendText("Mac 接收目录不可用。", status: "503 Service Unavailable", connection: connection)
            return
        }
        let safeName = safeFilename(filename)
        let finalURL = uniqueDestination(directory: destinationDirectory, filename: safeName)
        let temporaryURL = destinationDirectory.appendingPathComponent(".\(safeName).phonebridge-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temporaryURL) else {
            sendText("Mac 无法创建接收文件。", status: "500 Internal Server Error", connection: connection)
            return
        }

        let context = UploadContext(
            connection: connection,
            handle: handle,
            temporaryURL: temporaryURL,
            finalURL: finalURL,
            remainingBytes: contentLength
        )
        consumeUploadData(initialBody, context: context)
    }

    nonisolated private func consumeUploadData(_ data: Data, context: UploadContext) {
        if !data.isEmpty, context.remainingBytes > 0 {
            let count = min(Int64(data.count), context.remainingBytes)
            context.handle.write(data.prefix(Int(count)))
            context.remainingBytes -= count
        }

        if context.remainingBytes == 0 {
            try? context.handle.close()
            do {
                try FileManager.default.moveItem(at: context.temporaryURL, to: context.finalURL)
                let didSetTransferDate = (try? FileManager.default.setAttributes(
                    [.modificationDate: Date()],
                    ofItemAtPath: context.finalURL.path
                )) != nil
                sendText("上传完成", connection: context.connection)
                DispatchQueue.main.async {
                    self.receivedFiles.insert(context.finalURL.lastPathComponent, at: 0)
                    self.onStatus?(didSetTransferDate
                        ? "已无线接收：\(context.finalURL.lastPathComponent)（日期已更新为完成时间）"
                        : "已无线接收：\(context.finalURL.lastPathComponent)，但无法更新修改日期。")
                    self.onFilesReceived?()
                }
            } catch {
                try? FileManager.default.removeItem(at: context.temporaryURL)
                sendText("保存文件失败：\(error.localizedDescription)", status: "500 Internal Server Error", connection: context.connection)
            }
            return
        }

        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self, context] data, _, isComplete, error in
            guard let self else {
                try? context.handle.close()
                try? FileManager.default.removeItem(at: context.temporaryURL)
                context.connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                self.consumeUploadData(data, context: context)
            } else if isComplete || error != nil {
                try? context.handle.close()
                try? FileManager.default.removeItem(at: context.temporaryURL)
                self.sendText("上传中断。", status: "400 Bad Request", connection: context.connection)
            } else {
                self.consumeUploadData(Data(), context: context)
            }
        }
    }

    nonisolated private func sendContinue(connection: NWConnection, completion: @escaping () -> Void) {
        connection.send(
            content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
            completion: .contentProcessed { error in
                if error == nil {
                    completion()
                } else {
                    connection.cancel()
                }
            }
        )
    }

    nonisolated private func sendSharedFile(index: Int, connection: NWConnection) {
        guard sharedFileURLs.indices.contains(index) else {
            sendText("共享文件已不存在。", status: "404 Not Found", connection: connection)
            return
        }
        let fileURL = sharedFileURLs[index]
        guard
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: fileURL) else {
            sendText("共享文件已不存在。", status: "404 Not Found", connection: connection)
            return
        }
        let mime = mimeType(for: fileURL)
        let encodedName = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "PhoneBridge-file"
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(fileSize)\r\nContent-Disposition: attachment; filename*=UTF-8''\(encodedName)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? handle.close()
                connection.cancel()
                return
            }
            self.sendNextFileChunk(handle: handle, connection: connection)
        })
    }

    nonisolated private func sendNextFileChunk(handle: FileHandle, connection: NWConnection) {
        let data = handle.readData(ofLength: 512 * 1_024)
        if data.isEmpty {
            try? handle.close()
            connection.cancel()
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                try? handle.close()
                connection.cancel()
                return
            }
            self.sendNextFileChunk(handle: handle, connection: connection)
        })
    }

    nonisolated private func sendHTML(_ html: String, connection: NWConnection) {
        send(Data(html.utf8), contentType: "text/html; charset=utf-8", connection: connection)
    }

    nonisolated private func sendText(_ text: String, status: String = "200 OK", connection: NWConnection) {
        send(Data(text.utf8), status: status, contentType: "text/plain; charset=utf-8", connection: connection)
    }

    nonisolated private func send(
        _ body: Data,
        status: String = "200 OK",
        contentType: String,
        connection: NWConnection
    ) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    nonisolated private func safeFilename(_ filename: String) -> String {
        let candidate = (filename as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return candidate.isEmpty ? "PhoneBridge-\(UUID().uuidString)" : candidate
    }

    nonisolated private func uniqueDestination(directory: URL, filename: String) -> URL {
        let original = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for number in 1...9_999 {
            let nextName = ext.isEmpty ? "\(stem) (\(number))" : "\(stem) (\(number)).\(ext)"
            let next = directory.appendingPathComponent(nextName)
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
    }

    nonisolated private func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "cer", "crt": return "application/x-x509-ca-cert"
        case "mobileconfig": return "application/x-apple-aspen-config"
        case "pem": return "application/x-pem-file"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "heic": return "image/heic"
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }

    nonisolated private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    nonisolated private static func localIPv4Addresses() -> [String] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var candidates: [(String, String)] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                candidates.append((name, String(cString: host)))
            }
        }

        return candidates
            .sorted { lhs, rhs in
                let lhsRank = lhs.0.hasPrefix("en") ? 0 : 1
                let rhsRank = rhs.0.hasPrefix("en") ? 0 : 1
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.0.localizedStandardCompare(rhs.0) == .orderedAscending
            }
            .map(\.1)
            .reduce(into: [String]()) { result, address in
                if !result.contains(address) { result.append(address) }
            }
    }
}

private final class UploadContext: @unchecked Sendable {
    let connection: NWConnection
    let handle: FileHandle
    let temporaryURL: URL
    let finalURL: URL
    var remainingBytes: Int64

    init(
        connection: NWConnection,
        handle: FileHandle,
        temporaryURL: URL,
        finalURL: URL,
        remainingBytes: Int64
    ) {
        self.connection = connection
        self.handle = handle
        self.temporaryURL = temporaryURL
        self.finalURL = finalURL
        self.remainingBytes = remainingBytes
    }
}
