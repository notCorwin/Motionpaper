/// A resource that keeps the native wallpaper playing until released.
@MainActor
public protocol PlaybackSession: AnyObject {
    func release()
}

/// An acquisition failure that cannot be resolved by retrying.
public protocol NonRetryablePlaybackError: Error {}

@MainActor
public final class PlaybackController {
    public enum State: Equatable {
        case disabled
        case starting
        case enabled
        case retrying(String)
        case failed(String)
    }

    public private(set) var state: State = .disabled {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: (@MainActor (State) -> Void)?

    private let acquire: @MainActor () async throws -> any PlaybackSession
    private let acquisitionTimeout: Duration
    private let retryInterval: Duration
    private var isEnabled = false
    private var session: (any PlaybackSession)?
    private var request: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(acquisitionTimeout: Duration = .seconds(10),
                retryInterval: Duration = .seconds(3),
                acquire: @escaping @MainActor () async throws -> any PlaybackSession) {
        precondition(acquisitionTimeout > .zero, "acquisitionTimeout must be positive")
        precondition(retryInterval > .zero, "retryInterval must be positive")
        self.acquisitionTimeout = acquisitionTimeout
        self.retryInterval = retryInterval
        self.acquire = acquire
    }

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            startAcquisition()
            return
        }

        generation &+= 1
        let currentGeneration = generation
        let previousRequest = request
        let previousTimeout = timeout
        let previousRetry = retry
        let previousSession = session
        request = nil
        timeout = nil
        retry = nil
        session = nil
        previousRequest?.cancel()
        previousTimeout?.cancel()
        previousRetry?.cancel()
        previousSession?.release()
        guard generation == currentGeneration, !isEnabled else { return }
        state = .disabled
    }

    private func startAcquisition() {
        generation &+= 1
        let currentGeneration = generation
        request = Task { @MainActor [weak self, acquire] in
            guard !Task.isCancelled, self?.generation == currentGeneration,
                  self?.isEnabled == true else { return }
            do {
                let acquired = try await acquire()
                guard let self, self.generation == currentGeneration,
                      self.isEnabled, !Task.isCancelled else {
                    acquired.release()
                    return
                }
                self.session = acquired
                self.request = nil
                let previousTimeout = self.timeout
                self.timeout = nil
                previousTimeout?.cancel()
                guard self.generation == currentGeneration, self.isEnabled else { return }
                self.state = .enabled
            } catch {
                guard let self, self.generation == currentGeneration,
                      self.isEnabled, !Task.isCancelled else { return }
                self.request = nil
                let previousTimeout = self.timeout
                self.timeout = nil
                previousTimeout?.cancel()
                guard self.generation == currentGeneration, self.isEnabled else { return }
                let message = String(describing: error)
                if error is any NonRetryablePlaybackError {
                    self.state = .failed(message)
                } else {
                    self.scheduleRetry(message)
                }
            }
        }
        // Native acquisition can ignore cancellation or never resume, so its
        // deadline must not wait for the request task to finish.
        timeout = Task { @MainActor [weak self, acquisitionTimeout] in
            do { try await Task.sleep(for: acquisitionTimeout) }
            catch { return }
            guard let self, self.generation == currentGeneration,
                  self.isEnabled, !Task.isCancelled else { return }
            self.generation &+= 1
            let timeoutGeneration = self.generation
            let previousRequest = self.request
            self.request = nil
            self.timeout = nil
            previousRequest?.cancel()
            guard self.generation == timeoutGeneration, self.isEnabled else { return }
            self.scheduleRetry("开始播放超时。")
        }
        // Keep recovery visible while the next acquisition is in flight.
        if case .retrying = state { return }
        state = .starting
    }

    private func scheduleRetry(_ message: String) {
        generation &+= 1
        let currentGeneration = generation
        retry = Task { @MainActor [weak self, retryInterval] in
            do { try await Task.sleep(for: retryInterval) }
            catch { return }
            guard let self, self.generation == currentGeneration,
                  self.isEnabled, !Task.isCancelled else { return }
            self.retry = nil
            self.startAcquisition()
        }
        state = .retrying(message)
    }
}
