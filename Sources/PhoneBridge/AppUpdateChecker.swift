import AppKit
import Foundation

struct ReleaseVersion: Comparable, Equatable {
    let components: [Int]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") {
            value.removeFirst()
        }
        value = value.split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
        value = value.split(separator: "-", maxSplits: 1).first.map(String.init) ?? value

        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        let parsed = parts.compactMap { Int($0) }
        guard parsed.count == parts.count, parsed.allSatisfy({ $0 >= 0 }) else { return nil }
        components = parsed
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

enum AppUpdatePolicy {
    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60

    static func isNewerRelease(tagName: String, than currentVersion: String) -> Bool {
        guard let release = ReleaseVersion(tagName),
              let current = ReleaseVersion(currentVersion) else { return false }
        return release > current
    }

    static func shouldCheckAutomatically(
        lastSuccessfulCheck: Date?,
        now: Date,
        interval: TimeInterval = automaticCheckInterval
    ) -> Bool {
        guard let lastSuccessfulCheck else { return true }
        guard lastSuccessfulCheck <= now else { return true }
        return now.timeIntervalSince(lastSuccessfulCheck) >= interval
    }
}

struct GitHubReleaseLocation: Equatable {
    let tagName: String
    let releaseURL: URL

    init?(redirectedURL: URL, repository: String) {
        guard redirectedURL.scheme?.lowercased() == "https",
              redirectedURL.host?.lowercased() == "github.com" else { return nil }

        let repositoryParts = repository.split(separator: "/").map(String.init)
        let pathParts = redirectedURL.path.split(separator: "/").map(String.init)
        guard repositoryParts.count == 2,
              pathParts.count == 5,
              pathParts[0].caseInsensitiveCompare(repositoryParts[0]) == .orderedSame,
              pathParts[1].caseInsensitiveCompare(repositoryParts[1]) == .orderedSame,
              pathParts[2] == "releases",
              pathParts[3] == "tag" else { return nil }

        let tagName = pathParts[4].removingPercentEncoding ?? pathParts[4]
        guard ReleaseVersion(tagName) != nil else { return nil }

        var canonicalComponents = URLComponents(
            url: redirectedURL,
            resolvingAgainstBaseURL: false
        )
        canonicalComponents?.query = nil
        canonicalComponents?.fragment = nil
        guard let releaseURL = canonicalComponents?.url else { return nil }

        self.tagName = tagName
        self.releaseURL = releaseURL
    }
}

struct AvailableAppUpdate: Identifiable {
    let currentVersion: String
    let version: String
    let title: String
    let releaseURL: URL

    var id: String { version }
}

struct UpdateCheckNotice: Identifiable {
    let title: String
    let message: String

    var id: String { title + message }
}

private enum AppUpdateCheckError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidRelease

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub 返回了无法识别的响应。"
        case .httpStatus(403):
            return "GitHub 拒绝了更新请求，请检查网络或代理后重试。"
        case .httpStatus(429):
            return "GitHub 暂时限制了访问频率，请稍后再试。"
        case .httpStatus(404):
            return "GitHub 仓库还没有可用的正式 Release。"
        case .httpStatus(let status):
            return "GitHub 检查失败（HTTP \(status)）。"
        case .invalidRelease:
            return "GitHub Release 的版本或下载地址无效。"
        }
    }
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    static let repository = "Miraitwo/PhoneBridge"
    private static let lastSuccessfulCheckKey = "PhoneBridge.lastSuccessfulUpdateCheck"
    private static let latestReleaseURL = URL(
        string: "https://github.com/\(repository)/releases/latest"
    )!

    @Published private(set) var isChecking = false
    @Published var availableUpdate: AvailableAppUpdate?
    @Published var notice: UpdateCheckNotice?

    private let session: URLSession
    private let defaults: UserDefaults
    private let now: () -> Date
    private let currentVersion: () -> String

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        currentVersion: @escaping () -> String = {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "0.0.0"
        }
    ) {
        self.session = session
        self.defaults = defaults
        self.now = now
        self.currentVersion = currentVersion
    }

    func checkAutomatically() async {
        let lastCheck = defaults.object(forKey: Self.lastSuccessfulCheckKey) as? Date
        guard AppUpdatePolicy.shouldCheckAutomatically(
            lastSuccessfulCheck: lastCheck,
            now: now()
        ) else { return }
        await check(interactive: false)
    }

    func checkNow() async {
        await check(interactive: true)
    }

    func openRelease(_ update: AvailableAppUpdate) {
        NSWorkspace.shared.open(update.releaseURL)
    }

    private func check(interactive: Bool) async {
        guard !isChecking else {
            if interactive {
                notice = UpdateCheckNotice(title: "正在检查更新", message: "请稍候。")
            }
            return
        }

        isChecking = true
        defer { isChecking = false }

        let currentVersion = currentVersion()

        do {
            var request = URLRequest(
                url: Self.latestReleaseURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15
            )
            request.httpMethod = "HEAD"
            request.setValue("PhoneBridge/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw AppUpdateCheckError.invalidResponse
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw AppUpdateCheckError.httpStatus(httpResponse.statusCode)
            }
            guard let redirectedURL = httpResponse.url,
                  let release = GitHubReleaseLocation(
                    redirectedURL: redirectedURL,
                    repository: Self.repository
                  ) else {
                throw AppUpdateCheckError.invalidRelease
            }

            defaults.set(now(), forKey: Self.lastSuccessfulCheckKey)

            if AppUpdatePolicy.isNewerRelease(
                tagName: release.tagName,
                than: currentVersion
            ) {
                let normalizedVersion = release.tagName.lowercased().hasPrefix("v")
                    ? String(release.tagName.dropFirst())
                    : release.tagName
                availableUpdate = AvailableAppUpdate(
                    currentVersion: currentVersion,
                    version: normalizedVersion,
                    title: "PhoneBridge \(normalizedVersion)",
                    releaseURL: release.releaseURL
                )
            } else if interactive {
                notice = UpdateCheckNotice(
                    title: "已是最新版本",
                    message: "当前版本为 PhoneBridge \(currentVersion)。"
                )
            }
        } catch {
            guard interactive else { return }
            notice = UpdateCheckNotice(
                title: "无法检查更新",
                message: (error as? LocalizedError)?.errorDescription
                    ?? "请检查网络、代理或 GitHub 访问状态后重试。"
            )
        }
    }
}
