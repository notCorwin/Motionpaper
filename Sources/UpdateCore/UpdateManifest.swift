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

    public static func decode(_ data: Data, releaseURL: URL) throws -> Self {
        guard data.count <= 65_536 else { throw UpdateError.invalidManifest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(Release.self, from: data)
        guard let repository = autobuildRepository(in: releaseURL),
              !release.draft, !release.prerelease,
              release.tagName.hasPrefix("Autobuild-") else { throw UpdateError.invalidManifest }

        let commit = String(release.tagName.dropFirst("Autobuild-".count))
        guard isHex(commit, count: 40) else { throw UpdateError.invalidManifest }
        let name = "Motionpaper-\(commit.prefix(12)).dmg"
        let assets = release.assets.filter { $0.name == name }
        guard assets.count == 1, let asset = assets.first,
              asset.state == "uploaded", asset.size > 0,
              let digest = asset.digest, digest.hasPrefix("sha256:") else { throw UpdateError.invalidManifest }
        let checksum = String(digest.dropFirst("sha256:".count))
        let expected = "https://github.com/\(repository.owner)/\(repository.name)/releases/download/\(release.tagName)/\(name)"
        guard isHex(checksum, count: 64), asset.downloadURL.absoluteString == expected else {
            throw UpdateError.invalidManifest
        }
        return Self(commit: commit, publishedAt: release.publishedAt, downloadURL: asset.downloadURL,
                    sha256: checksum, size: asset.size)
    }

    /// Decodes and validates one formal release from the repository's releases list.
    public static func decodeStableRelease(_ data: Data, releaseURL: URL) throws -> Self {
        guard data.count <= 1_048_576, let repository = stableRepository(in: releaseURL) else {
            throw UpdateError.invalidManifest
        }
        let release = try JSONDecoder().decode(StableRelease.self, from: data)
        guard !release.draft, !release.prerelease,
              release.tagName.hasPrefix("v"),
              let version = ReleaseVersion(String(release.tagName.dropFirst())),
              isHex(release.targetCommitish, count: 40),
              let publishedAt = decodeISO8601(release.publishedAt) else {
            throw UpdateError.invalidManifest
        }

        let commit = release.targetCommitish
        let name = "Motionpaper-\(version)-\(commit.prefix(12)).dmg"
        let assets = release.assets.filter { $0.name == name }
        guard assets.count == 1, let asset = assets.first,
              asset.state == "uploaded", asset.size > 0,
              let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw UpdateError.invalidManifest
        }
        let checksum = String(digest.dropFirst("sha256:".count))
        let expected = "https://github.com/\(repository.owner)/\(repository.name)/releases/download/\(release.tagName)/\(name)"
        guard isHex(checksum, count: 64), asset.downloadURL.absoluteString == expected else {
            throw UpdateError.invalidManifest
        }
        return Self(commit: commit, publishedAt: publishedAt, downloadURL: asset.downloadURL,
                    sha256: checksum, size: asset.size, version: version)
    }

    static func autobuildRepository(in releaseURL: URL) -> (owner: String, name: String)? {
        let components = releaseURL.pathComponents
        guard components.count == 6, components[1] == "repos",
              isRepositoryComponent(components[2]), isRepositoryComponent(components[3]),
              Array(components.suffix(2)) == ["releases", "latest"],
              releaseURL.absoluteString == "https://api.github.com/repos/\(components[2])/\(components[3])/releases/latest" else {
            return nil
        }
        return (components[2], components[3])
    }

    static func stableRepository(in releaseURL: URL) -> (owner: String, name: String)? {
        let components = releaseURL.pathComponents
        guard components.count == 5, components[1] == "repos",
              isRepositoryComponent(components[2]), isRepositoryComponent(components[3]),
              components[4] == "releases",
              releaseURL.absoluteString == "https://api.github.com/repos/\(components[2])/\(components[3])/releases?per_page=100" else {
            return nil
        }
        return (components[2], components[3])
    }

    private struct Release: Decodable {
        let tagName: String
        let publishedAt: Date
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case publishedAt = "published_at"
            case draft, prerelease, assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let state: String
        let downloadURL: URL
        let digest: String?
        let size: Int64

        enum CodingKeys: String, CodingKey {
            case downloadURL = "browser_download_url"
            case name, state, digest, size
        }
    }

    private struct StableRelease: Decodable {
        let tagName: String
        let targetCommitish: String
        let publishedAt: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case targetCommitish = "target_commitish"
            case publishedAt = "published_at"
            case draft, prerelease, assets
        }
    }

    private static func isRepositoryComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func decodeISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
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
