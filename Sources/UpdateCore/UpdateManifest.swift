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
        let expected = "https://github.com/\(components[1])/\(components[2])/releases/download/\(manifest.commit)/Wavepaper-\(manifest.shortCommit).dmg"
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

    public var errorDescription: String? {
        switch self {
        case .invalidManifest: "更新信息无效，请稍后重试。"
        case .httpStatus(404): "暂时没有可用的 Release，请稍后重试。"
        case .httpStatus(let code): "更新服务器返回错误（HTTP \(code)），请稍后重试。"
        case .checksumMismatch: "安装镜像校验失败，请重新下载。"
        }
    }
}
