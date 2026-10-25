import Foundation
import Testing
@testable import UpdateCore

private let feed = URL(string: "https://github.com/notCorwin/Wavepaper/releases/latest/download/update.json")!
private let commit = String(repeating: "a", count: 40)
private let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

private func manifestData(commit: String = commit, checksum: String = digest, size: Int = 3,
                          download: String? = nil) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "commit": commit, "publishedAt": "2026-10-25T00:00:00Z",
        "downloadURL": download ?? "https://github.com/notCorwin/Wavepaper/releases/download/\(commit)/Wavepaper-\(commit.prefix(12)).dmg",
        "sha256": checksum, "size": size,
    ])
}

@Test func manifestBindsArtifactToRepositoryAndCommit() throws {
    let manifest = try UpdateManifest.decode(manifestData(), manifestURL: feed)
    #expect(manifest.commit == commit)
    #expect(manifest.shortCommit == "aaaaaaaaaaaa")
    #expect(manifest.size == 3)
    for address in [
        "https://example.com/Wavepaper.dmg",
        "https://github.com/another/Wavepaper/releases/download/\(commit)/Wavepaper-aaaaaaaaaaaa.dmg",
        "https://github.com/notCorwin/Wavepaper/releases/latest/download/Wavepaper-aaaaaaaaaaaa.dmg",
        "https://github.com/notCorwin/Wavepaper/releases/download/\(commit)/Wavepaper-aaaaaaaaaaaa.dmg?redirect=1",
    ] {
        #expect(throws: (any Error).self) { try UpdateManifest.decode(manifestData(download: address), manifestURL: feed) }
    }
    #expect(throws: (any Error).self) { try UpdateManifest.decode(manifestData(commit: "abc"), manifestURL: feed) }
    #expect(throws: (any Error).self) { try UpdateManifest.decode(manifestData(checksum: "bad"), manifestURL: feed) }
    #expect(throws: (any Error).self) { try UpdateManifest.decode(manifestData(size: 0), manifestURL: feed) }
}

@Test func downloadValidationRejectsTamperingAndReusesVerifiedCache() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifest = try UpdateManifest.decode(manifestData(), manifestURL: feed)
    let file = directory.appendingPathComponent("\(commit)-\(digest).dmg")
    try Data("abc".utf8).write(to: file)
    #expect(try UpdateService.verify(file, manifest: manifest))
    // A valid cache must work without any network access.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateProtocol.self]
    let service = UpdateService(manifestURL: feed, currentCommit: "other", directory: directory,
                                session: URLSession(configuration: configuration))
    #expect(try await service.download(manifest) == file)
    try Data("abd".utf8).write(to: file)
    #expect(try !UpdateService.verify(file, manifest: manifest))
    try Data("ab".utf8).write(to: file)
    #expect(try !UpdateService.verify(file, manifest: manifest))
}

// Session-local transport keeps these tests independent of the network.
private final class UpdateProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.url?.query == "missing" ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? manifestData()) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func checkingComparesFullCommitAndPropagatesHTTPFailures() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [UpdateProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let directory = FileManager.default.temporaryDirectory
    let current = UpdateService(manifestURL: feed, currentCommit: commit, directory: directory, session: session)
    #expect(try await current.check() == nil)
    let older = UpdateService(manifestURL: feed, currentCommit: String(repeating: "b", count: 40), directory: directory, session: session)
    #expect(try await older.check()?.commit == commit)
    let missing = UpdateService(manifestURL: URL(string: feed.absoluteString + "?missing")!, currentCommit: commit, directory: directory, session: session)
    await #expect(throws: UpdateError.self) { try await missing.check() }
}
