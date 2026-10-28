import Foundation

public struct UpdateManifest: Equatable, Sendable {
    public let commit: String
    public let publishedAt: Date
    public let downloadURL: URL
    public let sha256: String
    public let size: Int64
    public let version: ReleaseVersion?

    public var shortCommit: String { String(commit.prefix(12)) }

    public init(commit: String, publishedAt: Date, downloadURL: URL, sha256: String, size: Int64,
                version: ReleaseVersion? = nil) {
        self.commit = commit
        self.publishedAt = publishedAt
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.size = size
        self.version = version
    }
}

/// One static document supplies both channels without querying the GitHub API.
struct UpdateFeed: Sendable {
    let autobuild: UpdateManifest?
    let stable: UpdateManifest?

    init(data: Data, url: URL) throws {
        guard data.count <= 16_384,
              let repository = Self.repository(in: url) else { throw UpdateError.invalidManifest }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            autobuild = try document.autobuild?.manifest(channel: .autobuild, repository: repository)
            stable = try document.stable?.manifest(channel: .stable, repository: repository)
            guard autobuild != nil || stable != nil else { throw UpdateError.invalidManifest }
        } catch {
            throw UpdateError.invalidManifest
        }
    }

    private struct Document: Decodable {
        let autobuild: Entry?
        let stable: Entry?
    }

    private struct Entry: Decodable {
        let commit: String
        let publishedAt: String
        let downloadURL: URL
        let sha256: String
        let size: Int64
        let version: String?

        func manifest(channel: UpdateChannel, repository: String) throws -> UpdateManifest {
            guard isHex(commit, count: 40), isHex(sha256, count: 64), size > 0,
                  let date = decodeISO8601(publishedAt) else { throw UpdateError.invalidManifest }
            let releaseVersion: ReleaseVersion?
            let tag: String
            let name: String
            switch channel {
            case .autobuild:
                guard version == nil else { throw UpdateError.invalidManifest }
                releaseVersion = nil
                tag = "Autobuild"
                name = "Motionpaper-\(commit.prefix(12)).dmg"
            case .stable:
                guard let version, let parsed = ReleaseVersion(version) else { throw UpdateError.invalidManifest }
                releaseVersion = parsed
                tag = "v\(parsed)"
                name = "Motionpaper-\(tag).dmg"
            }
            guard downloadURL.absoluteString == "https://github.com/\(repository)/releases/download/\(tag)/\(name)" else {
                throw UpdateError.invalidManifest
            }
            return UpdateManifest(commit: commit, publishedAt: date, downloadURL: downloadURL,
                                  sha256: sha256, size: size, version: releaseVersion)
        }
    }

    private static func repository(in url: URL) -> String? {
        let components = url.pathComponents
        guard components.count == 5, components[3] == "updates", components[4] == "update.json",
              [components[1], components[2]].allSatisfy({ value in
                  !value.isEmpty && value != "." && value != ".." && value.utf8.allSatisfy {
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                          || $0 == 45 || $0 == 46 || $0 == 95
                  }
              }) else { return nil }
        let repository = "\(components[1])/\(components[2])"
        guard url.absoluteString == "https://raw.githubusercontent.com/\(repository)/updates/update.json" else { return nil }
        return repository
    }
}

private func isHex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

private func decodeISO8601(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

public enum UpdateError: LocalizedError {
    case invalidManifest
    case httpStatus(Int)
    case checksumMismatch
    case installLocation
    case invalidApplication
    case installCommand(String, Int32)
    case installerUnavailable
    case applicationStillRunning
    case installationChanged
    case rollbackFailed(String)
    case unsupportedVolume
    case launchFailed
    case installationInProgress

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: "更新信息无效，请稍后重试。"
        case .httpStatus(404): "暂时没有可用的 Release，请稍后重试。"
        case .httpStatus(let code): "更新服务器返回错误（HTTP \(code)），请稍后重试。"
        case .checksumMismatch: "安装镜像校验失败，请重新下载。"
        case .installLocation: "当前运行位置无法自动更新。请将 Motionpaper 移至可写的 Applications 文件夹后重新打开。"
        case .invalidApplication: "镜像中的应用无效或与更新版本不一致，原应用未被替换。"
        case .installCommand(let command, let status): "准备更新失败（\(command)：\(status)），请重试。"
        case .installerUnavailable: "无法启动更新安装器，原应用未被替换，请重试。"
        case .applicationStillRunning: "Motionpaper 未能及时退出，更新已取消，请重试。"
        case .installationChanged: "已安装的应用在更新期间发生变化，更新已取消，请重新检查更新。"
        case .rollbackFailed(let path): "无法恢复旧版本。旧应用保留在 \(path)，请将其移回原安装位置。"
        case .unsupportedVolume: "当前磁盘不支持安全替换应用，请将 Motionpaper 移至本机的 Applications 文件夹后重试。"
        case .launchFailed: "新版本未能完成启动，已尝试恢复并重新打开旧版本。"
        case .installationInProgress: "Motionpaper 正在安装更新，请稍后重新打开。"
        }
    }
}
