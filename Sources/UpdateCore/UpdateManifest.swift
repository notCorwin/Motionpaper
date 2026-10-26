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
        guard data.count <= 1_048_576,
              let repository = repository(in: releaseURL) else { throw UpdateError.invalidManifest }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard
              !release.draft, !release.prerelease,
              let commit = autobuildCommit(from: release.tagName),
              let publishedAt = decodeISO8601(release.publishedAt) else { throw UpdateError.invalidManifest }

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
        return Self(commit: commit, publishedAt: publishedAt, downloadURL: asset.downloadURL,
                    sha256: checksum, size: asset.size)
    }

    /// Returns the publication date only for a strict, final Autobuild release.
    static func autobuildPublishedAt(in data: Data) throws -> Date? {
        guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let draft = release["draft"] as? Bool,
              let prerelease = release["prerelease"] as? Bool else { throw UpdateError.invalidManifest }
        guard !draft, !prerelease,
              let tagName = release["tag_name"] as? String,
              autobuildCommit(from: tagName) != nil else { return nil }
        guard let publishedAt = release["published_at"] as? String,
              let date = decodeISO8601(publishedAt) else { throw UpdateError.invalidManifest }
        return date
    }

    /// Returns the semantic version only for a final, formally versioned release.
    static func stableVersion(in data: Data) throws -> ReleaseVersion? {
        guard let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let draft = release["draft"] as? Bool,
              let prerelease = release["prerelease"] as? Bool else { throw UpdateError.invalidManifest }
        guard !draft, !prerelease,
              let tagName = release["tag_name"] as? String,
              tagName.hasPrefix("v") else { return nil }
        return ReleaseVersion(String(tagName.dropFirst()))
    }

    /// Decodes and validates one formal release from the repository's releases list.
    public static func decodeStableRelease(_ data: Data, releaseURL: URL) throws -> Self {
        guard data.count <= 1_048_576, let repository = repository(in: releaseURL) else {
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
        let name = "Motionpaper-v\(version).dmg"
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

    static func repository(in releaseURL: URL) -> (owner: String, name: String)? {
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
        let publishedAt: String
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

    private static func autobuildCommit(from tagName: String) -> String? {
        guard tagName.hasPrefix("Autobuild-") else { return nil }
        let commit = String(tagName.dropFirst("Autobuild-".count))
        return isHex(commit, count: 40) ? commit : nil
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
