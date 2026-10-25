import Foundation

public struct UpdateManifest: Codable, Equatable, Sendable {
    public let commit: String
    public let publishedAt: Date
    public let downloadURL: URL
    public let sha256: String
    public let size: Int64

    public var shortCommit: String { String(commit.prefix(12)) }

    public static func decode(_ data: Data, manifestURL: URL) throws -> Self {
        guard data.count <= 65_536 else { throw UpdateError.invalidManifest }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(Self.self, from: data)
        let components = manifestURL.pathComponents
        guard manifestURL.scheme == "https", manifestURL.host == "github.com",
              manifestURL.user == nil, manifestURL.password == nil, manifestURL.port == nil,
              manifestURL.query == nil, manifestURL.fragment == nil,
              components.count == 7,
              Array(components.suffix(4)) == ["releases", "latest", "download", "update.json"],
              isHex(manifest.commit, count: 40), isHex(manifest.sha256, count: 64),
              manifest.size > 0 else { throw UpdateError.invalidManifest }

        // Bind downloads to the same repository and immutable commit as the feed.
        let expected = "https://github.com/\(components[1])/\(components[2])/releases/download/Autobuild-\(manifest.commit)/Motionpaper-\(manifest.shortCommit).dmg"
        guard manifest.downloadURL.absoluteString == expected else { throw UpdateError.invalidManifest }
        return manifest
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
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
