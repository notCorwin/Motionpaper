import Darwin
import Foundation
import Synchronization

/// Owns the transaction lock, including its release before inherited descriptors close.
public final class UpdateLease: Sendable {
    private let descriptor: Mutex<Int32?>

    init(fileDescriptor: Int32) {
        descriptor = Mutex(fileDescriptor)
    }

    public func close() throws {
        try descriptor.withLock { current in
            guard let descriptor = current else { return }
            current = nil
            // O_CLOEXEC closes inherited descriptors only at exec. Explicitly
            // unlock so a child cannot prolong this transaction's lease.
            let unlockError = flock(descriptor, LOCK_UN) == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            let closeError = Darwin.close(descriptor) == 0 ? nil : POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            if let error = unlockError ?? closeError { throw error }
        }
    }

    deinit { try? close() }
}
