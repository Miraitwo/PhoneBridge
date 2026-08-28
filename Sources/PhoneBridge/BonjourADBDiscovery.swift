import Darwin
import Foundation

@MainActor
final class BonjourADBDiscovery: NSObject {
    private let pairingBrowser = NetServiceBrowser()
    private let connectionBrowser = NetServiceBrowser()
    private var resolvingServices: [String: NetService] = [:]
    private var resolvedServices: [String: AndroidADBService.MDNSService] = [:]
    private(set) var failureDescription: String?
    private var isRunning = false

    override init() {
        super.init()
        pairingBrowser.delegate = self
        connectionBrowser.delegate = self
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        failureDescription = nil
        pairingBrowser.searchForServices(ofType: "_adb-tls-pairing._tcp.", inDomain: "local.")
        connectionBrowser.searchForServices(ofType: "_adb-tls-connect._tcp.", inDomain: "local.")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        pairingBrowser.stop()
        connectionBrowser.stop()
        resolvingServices.values.forEach { service in
            service.stop()
            service.delegate = nil
        }
        resolvingServices.removeAll()
        resolvedServices.removeAll()
    }

    var services: [AndroidADBService.MDNSService] {
        Array(resolvedServices.values)
    }

    private static func key(for service: NetService) -> String {
        "\(service.type.lowercased())|\(service.name.lowercased())"
    }

    private static func kind(for service: NetService) -> AndroidADBService.MDNSService.Kind? {
        switch service.type.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased() {
        case "_adb-tls-pairing._tcp": return .pairing
        case "_adb-tls-connect._tcp": return .connection
        default: return nil
        }
    }

    private static func endpoint(for service: NetService) -> String? {
        guard service.port > 0 else { return nil }

        let numericHosts = (service.addresses ?? []).compactMap(numericHost(from:))
        if let ipv4Host = numericHosts.first(where: { !$0.contains(":") }) {
            return "\(ipv4Host):\(service.port)"
        }
        if let ipv6Host = numericHosts.first {
            return "[\(ipv6Host)]:\(service.port)"
        }

        guard var host = service.hostName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else { return nil }
        while host.hasSuffix(".") {
            host.removeLast()
        }
        return host.contains(":") ? "[\(host)]:\(service.port)" : "\(host):\(service.port)"
    }

    private static func numericHost(from address: Data) -> String? {
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = address.withUnsafeBytes { rawBuffer -> Int32 in
            guard let baseAddress = rawBuffer.baseAddress else { return EAI_FAIL }
            return getnameinfo(
                baseAddress.assumingMemoryBound(to: sockaddr.self),
                socklen_t(address.count),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
        }
        guard result == 0 else { return nil }
        return String(cString: hostBuffer)
    }
}

extension BonjourADBDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            let key = Self.key(for: service)
            self.resolvingServices[key] = service
            service.delegate = self
            service.resolve(withTimeout: 5)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let key = Self.key(for: service)
            self.resolvingServices.removeValue(forKey: key)
            self.resolvedServices.removeValue(forKey: key)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let code = errorDict[NetService.errorCode]?.intValue ?? 0
            self.failureDescription = "macOS Bonjour 搜索失败（错误码 \(code)）。请检查系统设置中的本地网络权限。"
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        Task { @MainActor [weak self] in
            guard let self,
                  self.isRunning,
                  let kind = Self.kind(for: sender),
                  let endpoint = Self.endpoint(for: sender) else { return }
            let key = Self.key(for: sender)
            self.resolvedServices[key] = AndroidADBService.MDNSService(
                name: sender.name,
                kind: kind,
                endpoint: endpoint
            )
        }
    }

    nonisolated func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.resolvingServices.removeValue(forKey: Self.key(for: sender))
        }
    }
}
