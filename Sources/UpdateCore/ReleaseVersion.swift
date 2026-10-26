import Foundation

public enum UpdateChannel: String, Hashable, Sendable {
    case autobuild
    case stable
}

/// A strict three-part numeric release version (for example, `1.2.3`).
public struct ReleaseVersion: Comparable, Sendable, Equatable, CustomStringConvertible {
    private let components: [String]

    public var description: String { components.joined(separator: ".") }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
                      && (part == "0" || part.first != "0")
              }) else { return nil }
        components = parts
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        for (left, right) in zip(lhs.components, rhs.components) {
            if left.count != right.count { return left.count < right.count }
            if left != right { return left < right }
        }
        return false
    }
}
