/// A resource that keeps the native wallpaper playing until released.
@MainActor
public protocol PlaybackSession: AnyObject {
    func release()
}

@MainActor
public final class PlaybackController {
    public enum State: Equatable {
        case disabled
        case starting
        case enabled
        case failed(String)
    }

    public private(set) var state: State = .disabled {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: (@MainActor (State) -> Void)?

    private let acquire: @MainActor () async throws -> any PlaybackSession
    private let acquisitionTimeout: Duration
    private var session: (any PlaybackSession)?
    private var request: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(acquisitionTimeout: Duration = .seconds(10),
                acquire: @escaping @MainActor () async throws -> any PlaybackSession) {
        self.acquisitionTimeout = acquisitionTimeout
        self.acquire = acquire
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled && (state == .enabled || state == .starting) { return }
        generation &+= 1
        let currentGeneration = generation
        request?.cancel()
        request = nil
        timeout?.cancel()
        timeout = nil
        session?.release()
        session = nil
        guard enabled else {
            state = .disabled
            return
        }

        state = .starting
        request = Task { @MainActor [weak self, acquire] in
            do {
                let acquired = try await acquire()
                guard let self, self.generation == currentGeneration, !Task.isCancelled else {
                    acquired.release()
                    return
                }
                self.session = acquired
                self.request = nil
                self.timeout?.cancel()
                self.timeout = nil
                self.state = .enabled
            } catch {
                guard let self, self.generation == currentGeneration, !Task.isCancelled else { return }
                self.request = nil
                self.timeout?.cancel()
                self.timeout = nil
                self.state = .failed(String(describing: error))
            }
        }
        // The native request may ignore cancellation or never resume. Keep its
        // deadline independent so the controller can still expose a retry.
        timeout = Task { @MainActor [weak self, acquisitionTimeout] in
            do { try await Task.sleep(for: acquisitionTimeout) }
            catch { return }
            guard let self, self.generation == currentGeneration, self.state == .starting else { return }
            self.generation &+= 1
            self.request?.cancel()
            self.request = nil
            self.timeout = nil
            self.state = .failed("开始播放超时，请重试。")
        }
    }
}
